"""A zone level built from its committed recipe, and the lock that names what was built (ADR 009).

``build_level`` drives the bridge of a throwaway server whose default world is the
zone: ``pregen``, the recipe's steps, the zone's checks, ``scan_items``, the chorus
flower rule and the block fingerprint. It then calls ``after_stop``, which stops that
server and reports what only the saved folder and the engine know. ``build_level``
writes the lock last, from both, so a failure anywhere leaves no lock behind. The
recipe and lock formats are in ``levels/README.md``.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import re
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import yaml

from designer import checks as checks_mod
from designer.blocks import BlockClass, format_name, parse_name
from designer.bridge import Bridge
from designer.builders import BUILDERS
from designer.builders.base import Palette
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT, SIBLING_GAME_DIR
from designer.palettes import load_palettes
from designer.structure import StructureBuildError, StructureSpec, Converted, convert, load
from designer.region import Bounds, Bounds2D, Region, fetch_heightmap, fetch_region
from designer.reset_states import RESET_STATES
from designer.world_index import Location, NamedRegion, WorldIndex

ZONE_RE = re.compile(r"^[a-z0-9_]+$")
# The guard protects paths holding these words, and a build volume is named after
# its zone, so a zone carrying one would make its own volume unremovable (ADR 007 item 3).
FORBIDDEN_WORDS = ("world", "player", "backup")
MINES_CONFIG = Path("mines") / "resources" / "config.yml"
# A step of this kind builds from a pinned source rather than a palette (``structure.py``).
STRUCTURE = "structure"


class LevelError(Exception):
    """A recipe, its index entry or the build it drives is refused."""


@dataclass(frozen=True)
class Step:
    build: str
    spec: str
    palette: str | None


@dataclass(frozen=True)
class Recipe:
    zone: str
    path: Path
    generator: str
    seed: int
    bounds: Bounds
    steps: tuple[Step, ...]


@dataclass(frozen=True)
class Saved:
    """What ``after_stop`` reads once the server has saved and exited."""

    core_image: str
    designbridge_commit: str
    toolkit_commit: str
    size_bytes: int
    npcs: Any = None
    texts: Any = None


def refuse_name(zone: str) -> None:
    if not ZONE_RE.fullmatch(zone):
        raise LevelError(f"zone {zone!r} must match {ZONE_RE.pattern}")
    if hit := [word for word in FORBIDDEN_WORDS if word in zone]:
        raise LevelError(f"zone {zone!r} contains {hit[0]!r}, which the guard protects; pick another name")


def _input(root: Path, relative: str) -> Path:
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise LevelError(f"recipe input {relative!r} is not a file under {root}")
    return path


def load_recipe(zone: str, root: Path = PROJECT_ROOT) -> Recipe:
    refuse_name(zone)
    path = root / "levels" / f"{zone}.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        steps = tuple(
            Step(str(s["build"]), str(s["spec"]), None if s["build"] == STRUCTURE else str(s["palette"])) for s in data["steps"]
        )
        seed = data["seed"]
        # The lock copies this seed as authoritative, so a float or string that merely converts is refused.
        if type(seed) is not int:
            raise TypeError(f"seed must be an integer, got {seed!r}")
        recipe = Recipe(zone, path, str(data["generator"]), seed, Bounds.from_json(data["bounds"]), steps)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise LevelError(f"cannot read recipe {path}: {exc}") from exc
    palettes = load_palettes()["palettes"]
    for n, step in enumerate(recipe.steps):
        if step.build not in BUILDERS and step.build != STRUCTURE:
            raise LevelError(f"step {n}: no builder {step.build!r}")
        if step.palette is not None and step.palette not in palettes:
            raise LevelError(f"step {n}: no palette {step.palette!r} in palettes.json")
        spec_path = _input(root, step.spec)
        try:
            world = json.loads(spec_path.read_text(encoding="utf-8"))["world"]
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise LevelError(f"step {n}: cannot read the world of spec {step.spec}: {exc!r}") from exc
        if world != zone:
            raise LevelError(f"step {n} ({step.build} {step.spec}) writes world {world!r}, not the zone {zone!r}")
    return recipe


def structure_spec(step: Step, root: Path) -> StructureSpec:
    try:
        return StructureSpec.from_dict(json.loads(_input(root, step.spec).read_text(encoding="utf-8")))
    except (OSError, ValueError) as exc:
        raise LevelError(f"cannot read the structure spec {step.spec}: {exc}") from exc


def prepare_structures(recipe: Recipe, root: Path, out: Path) -> Converted | None:
    """Convert the recipe's ``structure`` step into cell files under ``out``, an empty directory; ``None`` without one.

    The conversion's sha256 of the structure must be the one ``pins.json`` records.
    """
    steps = [step for step in recipe.steps if step.build == STRUCTURE]
    if len(steps) > 1:
        raise LevelError(f"{recipe.zone!r} has {len(steps)} structure steps; the cells of two would share one directory")
    if not steps:
        return None
    spec = structure_spec(steps[0], root)
    if out.exists() and any(out.iterdir()):
        raise LevelError(f"{out} is not empty; cell files from another run would be loaded with these")
    source = _input(root, f"{spec.source}/{spec.file}")
    pinned = json.loads(_input(root, f"{spec.source}/pins.json").read_text(encoding="utf-8"))["structure_sha256"]
    out.mkdir(parents=True, exist_ok=True)
    try:
        converted = convert(source, out, spec)
    except StructureBuildError as exc:
        raise LevelError(f"cannot convert {source.name}: {exc}") from exc
    if converted.structure_sha256 != pinned:
        raise LevelError(f"{source.name} unpacks to sha256 {converted.structure_sha256}, pins.json records {pinned}")
    return converted


def check_index(recipe: Recipe, index: WorldIndex) -> None:
    """The recipe owns generator and seed; ``world_index.json`` must name the zone and agree."""
    try:
        entry = index.world(recipe.zone)
    except KeyError as exc:
        raise LevelError(f"world_index.json has no world {recipe.zone!r}; a built zone must be listed there") from exc
    theirs, ours = (entry.generator, entry.seed), (recipe.generator, recipe.seed)
    if theirs != ours:
        raise LevelError(f"world_index.json has {recipe.zone!r} as generator and seed {theirs}, the recipe {ours}")


def pregen_bounds(bounds: Bounds) -> Bounds2D:
    """The recipe's chunks plus one chunk on every horizontal side, so population at build time reaches the bounds' neighbours."""
    (x0, _, z0), (x1, _, z1) = bounds.min, bounds.max
    return Bounds2D((((x0 >> 4) - 1) * 16, ((z0 >> 4) - 1) * 16), (((x1 >> 4) + 2) * 16 - 1, ((z1 >> 4) + 2) * 16 - 1))


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def content_sha256(region: Region, npcs: Any = None, texts: Any = None) -> str:
    """Block states in ``y, z, x`` order over their sorted names, then the marker and text files when present.

    Sorting the names makes the hash independent of the order the bridge built its palette in.
    """
    names = sorted({region.palette[i] for i in np.unique(region.blocks)})
    lut = np.array([names.index(n) if n in names else 0 for n in region.palette], dtype="<u4")
    digest = hashlib.sha256(_canonical({"bounds": region.bounds.to_json(), "palette": names}))
    digest.update(np.ascontiguousarray(lut[region.blocks]).tobytes())
    for name, doc in (("design_npcs.json", npcs), ("design_texts.json", texts)):
        if doc is not None:
            digest.update(_canonical({name: doc}))
    return digest.hexdigest()


def input_hashes(recipe: Recipe, root: Path = PROJECT_ROOT) -> dict[str, str]:
    """The recipe, each step's spec, and each palette a step draws from, which is hashed as its own entry in ``palettes.json``."""
    out = {recipe.path.relative_to(root).as_posix(): hashlib.sha256(recipe.path.read_bytes()).hexdigest()}
    for step in recipe.steps:
        out[step.spec] = hashlib.sha256(_input(root, step.spec).read_bytes()).hexdigest()
        if step.palette is not None:
            out[f"palette:{step.palette}"] = hashlib.sha256(_canonical(load_palettes()["palettes"][step.palette])).hexdigest()
        else:
            source = structure_spec(step, root).source
            out[f"{source}/pins.json"] = hashlib.sha256(_input(root, f"{source}/pins.json").read_bytes()).hexdigest()
    return out


def scan(bridge: Bridge, zone: str) -> int:
    """Chunks the saved zone holds; any item or saved entity in them refuses the build."""
    result = bridge.call_job("scan_items", world=zone)["result"]
    if findings := result["findings"]:
        raise LevelError(f"{zone!r} holds {len(findings)} item or entity finding(s), first {findings[0]}")
    return int(result["chunks"])


def _comparable(entry: Location | NamedRegion) -> dict[str, Any]:
    if not isinstance(entry.tags, list):
        raise LevelError(f"{entry.name!r} has tags that are not a list: {entry.tags!r}")
    if bad := [t for t in entry.tags if not isinstance(t, str)]:
        raise LevelError(f"{entry.name!r} has a tag that is not a string: {bad[0]!r}")
    # Tags are only ever tested for membership and are saved in the order given, so their order does not matter.
    # A repeated tag still counts, so a committed entry is reproduced tag for tag.
    return {**entry.to_json(), "tags": sorted(entry.tags)}


def _differences(index: WorldIndex, locations: list[Any], regions: list[Any]) -> list[str]:
    """Each entry ``index`` already holds that the step names but does not reproduce exactly, and how it differs."""
    held = index.names()
    out = []
    for entry in (*map(Location.from_json, locations), *map(NamedRegion.from_json, regions)):
        theirs = held.get(entry.name)
        if theirs is None:
            continue
        if type(theirs) is not type(entry):
            out.append(f"{entry.name!r} is a {type(entry).__name__} in the step, a {type(theirs).__name__} in world_index.json")
            continue
        ours_j, theirs_j = _comparable(entry), _comparable(theirs)
        # Compared sorted, but each side's fields are quoted in the order they are written, so a committed tag list
        # reads in the same order as in world_index.json.
        ours_w, theirs_w = entry.to_json(), theirs.to_json()
        if fields := [f"{k} {ours_w[k]} (world_index.json {theirs_w[k]})" for k in ours_j if ours_j[k] != theirs_j[k]]:
            out.append(f"{entry.name!r} has {', '.join(fields)}")
    return out


def open_carve(bridge: Bridge, edits: Any) -> str | None:
    """The first cell inside a box of ``edits.extras["carve"]`` that is not solid terrain, described, or ``None``.

    A step that digs out what is there would open onto water, lava or a natural cave wherever it finds one.
    """
    for box in edits.extras.get("carve", []):
        region = fetch_region(bridge, edits.world, Bounds.from_json(box))
        if len(found := np.argwhere(region.classes() != BlockClass.SOLID)):
            iy, iz, ix = found[0]
            x, y, z = (int(v) for v in np.add(region.bounds.min, (ix, iy, iz)))
            return f"({x}, {y}, {z}) holds {region.get(x, y, z)}"
    return None


def _run_steps(bridge: Bridge, recipe: Recipe, root: Path, index: WorldIndex, converted: Converted | None) -> None:
    """Apply each step and register what it names in ``index``, so the zone's checks resolve against what was built.

    Instances are delivered the committed ``world_index.json``, not the build's copy, so a step may
    name a committed entry only by reproducing it exactly; anything else would let the checks and
    the lock pass on geometry the delivered index does not carry. A name an earlier step of this
    build made is refused, since one of the two entries would silently vanish.
    """
    def fetch(world: str, bounds: Bounds2D) -> Any:
        return fetch_heightmap(bridge, world, bounds)

    made: set[str] = set()
    for n, step in enumerate(recipe.steps):
        if step.build == STRUCTURE:
            if converted is None:
                raise LevelError(f"step {n} ({step.build} {step.spec}) has no converted cells; run prepare_structures first")
            load(bridge, structure_spec(step, root), converted.cells)
            continue
        spec = json.loads(_input(root, step.spec).read_text(encoding="utf-8"))
        edits = BUILDERS[step.build](spec, Palette.load(step.palette), fetch)
        locations, regions = edits.extras.get("locations", []), edits.extras.get("regions", [])
        try:
            again = sorted(made & set(index.preflight(locations, regions)))
        except (KeyError, ValueError) as exc:
            raise LevelError(f"step {n} ({step.build} {step.spec}) names an entry the index refuses: {exc}") from exc
        if again:
            raise LevelError(f"step {n} ({step.build} {step.spec}) names {again}, which an earlier step made")
        if differ := _differences(index, locations, regions):
            raise LevelError(f"step {n} ({step.build} {step.spec}) differs from world_index.json: {'; '.join(differ)}")
        if opened := open_carve(bridge, edits):
            raise LevelError(f"step {n} ({step.build} {step.spec}) carves into terrain that is not solid: {opened}")
        result = edits.apply(bridge)
        if not result.ok:
            raise LevelError(f"step {n} ({step.build} {step.spec}) failed: {result.errors[0]}")
        index.register(locations, regions, replace=True)
        made.update(e["name"] for e in (*locations, *regions))


def mines_config_path() -> Path:
    """RiftalMines' ``config.yml`` in ``RIFTAL_GAME_DIR``, else in the riftal-game checkout beside this repository."""
    game = os.environ.get("RIFTAL_GAME_DIR")
    return (Path(game) if game else SIBLING_GAME_DIR) / MINES_CONFIG


def _check_fragment_ores(zone: str, fragment: Path, built: list[str], root: Path) -> None:
    """The reset refills from the fragment's ``ores`` while ``mine_valid`` reads the spec's, so the two must be the same.

    RiftalMines reads no ``ore_layers`` and refills the whole interior from one flat mix, so a spec with any layer refuses.
    """
    try:
        ores = json.loads(fragment.read_text(encoding="utf-8"))["ores"]
        theirs = {format_name(*parse_name(name)): float(weight) for name, weight in dict(ores).items()}
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise LevelError(f"cannot read the ores of {zone!r}'s mines fragment {fragment}: {exc!r}") from exc
    for spec_path in built:
        spec = MineSpec.from_dict(json.loads(_input(root, spec_path).read_text(encoding="utf-8")))
        if spec.ore_layers:
            raise LevelError(
                f"{spec_path} has ore_layers, but RiftalMines refills {zone!r} from the mines fragment {fragment}'s"
                " flat ores alone; the reset would refill another mix"
            )
        ours = spec.ores
        if ours != theirs:
            raise LevelError(f"{spec_path} ores {ours} differ from the mines fragment {fragment} ores {theirs}; the reset would refill another mix")


def check_mine_gate(recipe: Recipe, specs: list[checks_mod.CheckSpec], mines_config: Path, root: Path = PROJECT_ROOT) -> None:
    """A world ``mines`` resets is built only with a zone-tagged ``mine_valid`` on a spec one of its ``mine`` steps builds (ADR 014 item 7).

    Without the world list no zone can be told apart from one ``mines`` resets, so every zone is refused.
    """
    try:
        worlds = yaml.safe_load(mines_config.read_text(encoding="utf-8"))["worlds"]
        if not isinstance(worlds, dict):
            raise TypeError(f"worlds is a {type(worlds).__name__}, not a mapping")
    except (OSError, yaml.YAMLError, KeyError, TypeError, UnicodeDecodeError) as exc:
        raise LevelError(f"cannot read the mines world list {mines_config}: {exc!r}; no zone is built without it") from exc
    if recipe.zone not in worlds:
        return
    built = {step.spec for step in recipe.steps if step.build == "mine"}
    _check_fragment_ores(recipe.zone, mines_config.parent / str(worlds[recipe.zone]), sorted(built), root)
    if not any(s.kind == "mine_valid" and s.zone == recipe.zone and s.args["spec"] in built for s in specs):
        raise LevelError(
            f"{mines_config} lists {recipe.zone!r}, but checks.yaml has no mine_valid with zone {recipe.zone!r}"
            f" on a spec a mine step of the recipe builds {sorted(built)}"
        )


def check_reset_states(recipe: Recipe, root: Path) -> None:
    """Every ore a ``mine`` step names has its reset state in ``RESET_STATES``; ``mine_valid`` could not tell it apart otherwise."""
    for step in recipe.steps:
        if step.build != "mine":
            continue
        spec = MineSpec.from_dict(json.loads(_input(root, step.spec).read_text(encoding="utf-8")))
        names = [*spec.ores, *(name for layer in spec.ore_layers for name in layer.ores)]
        if missing := sorted({parse_name(n)[0] for n in names} - set(RESET_STATES)):
            raise LevelError(f"{step.spec} names {missing}, which have no reset state in designer/reset_states.py")


def chorus_outside(region: Region, recipe: Recipe, root: Path) -> list[tuple[int, int, int]]:
    """Chorus flowers outside every interior a ``mine`` step builds: a projectile breaks one with no cancellable event (ADR 014)."""
    interiors = [
        MineSpec.from_dict(json.loads(_input(root, s.spec).read_text(encoding="utf-8"))).geometry().interior
        for s in recipe.steps if s.build == "mine"
    ]
    flowers = [i for i, name in enumerate(region.palette) if parse_name(name)[0] == "minecraft:chorus_flower"]
    x0, y0, z0 = region.bounds.min
    cells = [(x0 + int(ix), y0 + int(iy), z0 + int(iz)) for iy, iz, ix in np.argwhere(np.isin(region.blocks, flowers))]
    return [cell for cell in cells if not any(box.contains(cell) for box in interiors)]


def _zone_checks(recipe: Recipe, index: WorldIndex, all_specs: list[checks_mod.CheckSpec]) -> list[checks_mod.CheckSpec]:
    """The zone's checks, each resolved against the built index and reading the zone; any that does not refuses the build."""
    specs = [s for s in all_specs if s.zone == recipe.zone]
    if not specs:
        raise LevelError(f"checks.yaml has no check with zone {recipe.zone!r}; a zone is not built unchecked")
    worlds = [(s.id, checks_mod.check_world(index, s)) for s in specs]
    # A mistyped name must refuse the build rather than drop the check out of the gate.
    if unresolved := [i for i, world in worlds if world is None]:
        raise LevelError(f"checks.yaml has checks on {recipe.zone!r} naming nothing the built index resolves: {unresolved}")
    if elsewhere := [f"{i} reads {world!r}" for i, world in worlds if world != recipe.zone]:
        raise LevelError(f"checks.yaml has checks on {recipe.zone!r} that read another world: {elsewhere}")
    return specs


def _run_checks(bridge: Bridge, recipe: Recipe, index: WorldIndex, specs: list[checks_mod.CheckSpec], region: Region) -> dict[str, Any]:
    """Run ``specs`` over ``region``, the whole recipe box, and answer the counts of those that report any."""
    # scan() refuses every finding, a stricter test than offdisk_clear, so running it here would only scan the zone twice.
    report = checks_mod.run_checks(bridge, index, [s for s in specs if s.kind != "offdisk_clear"], loaded={recipe.zone: region})
    if report.failed:
        raise LevelError(f"{recipe.zone!r} failed {[f'{r.id}: {r.detail}' for r in report.failed]}")
    return {r.id: r.counts for r in report.results if r.counts}


def build_level(
    bridge: Bridge, zone: str, after_stop: Callable[[], Saved], *, root: Path = PROJECT_ROOT,
    index: WorldIndex | None = None, checks_path: Path | None = None, mines_config: Path | None = None,
    converted: Converted | None = None,
) -> Path:
    """Build ``zone`` on the server behind ``bridge`` and write its lock; the name, index and mine gate are checked before any call.

    ``converted`` is what ``prepare_structures`` made, whose directory the server mounts read-only at ``/structures``.
    """
    recipe = load_recipe(zone, root)
    # The build registers its steps' names into its own copy, never into the caller's index or the committed file.
    index = WorldIndex.load() if index is None else copy.deepcopy(index)
    check_index(recipe, index)
    specs = checks_mod.load_checks(checks_path)
    check_mine_gate(recipe, specs, mines_config_path() if mines_config is None else mines_config, root)
    check_reset_states(recipe, root)
    inputs = input_hashes(recipe, root)
    for tile in pregen_bounds(recipe.bounds).tiles():
        bridge.call_job("pregen", world=zone, bounds=tile.to_json())
    _run_steps(bridge, recipe, root, index, converted)
    zone_specs = _zone_checks(recipe, index, specs)
    region = fetch_region(bridge, zone, recipe.bounds)
    counts = _run_checks(bridge, recipe, index, zone_specs, region)
    chunks = scan(bridge, zone)
    if flowers := chorus_outside(region, recipe, root):
        raise LevelError(f"{zone!r} has {len(flowers)} chorus flower(s) outside every mine interior, first at {flowers[0]}")
    saved = after_stop()
    lock = {
        "zone": zone, "generator": recipe.generator, "seed": recipe.seed, "bounds": recipe.bounds.to_json(),
        "core_image": saved.core_image, "designbridge_commit": saved.designbridge_commit,
        "toolkit_commit": saved.toolkit_commit, "inputs": inputs, "chunks": chunks, "size_bytes": saved.size_bytes,
        "content_sha256": content_sha256(region, saved.npcs, saved.texts),
    }
    if counts:
        lock["counts"] = counts
    if converted is not None:
        lock["structure"] = {
            "structure_sha256": converted.structure_sha256, "cells": len(converted.cells), "cells_sha256": converted.cells_sha256,
            "substitutes": converted.mapping, "substituted": converted.substituted, "dropped_block_entities": converted.dropped_block_entities,
        }
    path = root / "levels" / f"{zone}.lock.json"
    path.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    return path
