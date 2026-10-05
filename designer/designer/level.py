"""A zone level built from its committed recipe, and the lock that names what was built (ADR 009).

``build_level`` drives the bridge of a throwaway server whose default world is the
zone: ``pregen``, the recipe's steps, the zone's checks, ``scan_items``, the chorus
flower rule and the block fingerprint. It then hands over to ``after_stop``, which
stops that server and reports what only the saved folder and the engine know, and
writes the lock last, so a failure anywhere leaves no lock behind. The recipe and lock formats are in
``levels/README.md``.
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
from designer.blocks import parse_name
from designer.bridge import Bridge
from designer.builders import BUILDERS
from designer.builders.base import Palette
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT
from designer.palettes import load_palettes
from designer.region import Bounds, Bounds2D, Region, fetch_heightmap, fetch_region
from designer.world_index import Location, NamedRegion, WorldIndex

ZONE_RE = re.compile(r"^[a-z0-9_]+$")
# The guard protects paths holding these words, and a build volume is named after
# its zone, so a zone carrying one would make its own volume unremovable (ADR 007 item 3).
FORBIDDEN_WORDS = ("world", "player", "backup")
MINES_CONFIG = Path("mines") / "resources" / "config.yml"


class LevelError(Exception):
    """A recipe, its index entry or the build it drives is refused."""


@dataclass(frozen=True)
class Step:
    build: str
    spec: str
    palette: str


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
        steps = tuple(Step(str(s["build"]), str(s["spec"]), str(s["palette"])) for s in data["steps"])
        recipe = Recipe(zone, path, str(data["generator"]), int(data["seed"]), Bounds.from_json(data["bounds"]), steps)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise LevelError(f"cannot read recipe {path}: {exc}") from exc
    for n, step in enumerate(recipe.steps):
        if step.build not in BUILDERS:
            raise LevelError(f"step {n}: no builder {step.build!r}")
        _input(root, step.spec)
    return recipe


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
        out[f"palette:{step.palette}"] = hashlib.sha256(_canonical(load_palettes()["palettes"][step.palette])).hexdigest()
    return out


def scan(bridge: Bridge, zone: str) -> int:
    """Chunks the saved zone holds; any item or saved entity in them refuses the build."""
    result = bridge.call_job("scan_items", world=zone)["result"]
    if findings := result["findings"]:
        raise LevelError(f"{zone!r} holds {len(findings)} item or entity finding(s), first {findings[0]}")
    return int(result["chunks"])


def _comparable(entry: Location | NamedRegion) -> dict[str, Any]:
    if bad := [t for t in entry.tags if not isinstance(t, str)]:
        raise LevelError(f"{entry.name!r} has a tag that is not a string: {bad[0]!r}")
    # Tags are only ever tested for membership and are saved in the order given, so their order is no difference.
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
        if fields := [f"{k} {ours_j[k]} (world_index.json {theirs_j[k]})" for k in ours_j if ours_j[k] != theirs_j[k]]:
            out.append(f"{entry.name!r} has {', '.join(fields)}")
    return out


def _run_steps(bridge: Bridge, recipe: Recipe, root: Path, index: WorldIndex) -> None:
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
        spec = json.loads(_input(root, step.spec).read_text(encoding="utf-8"))
        edits = BUILDERS[step.build](spec, Palette.load(step.palette), fetch)
        if edits.world != recipe.zone:
            raise LevelError(f"step {n} writes world {edits.world!r}, not the zone {recipe.zone!r}")
        locations, regions = edits.extras.get("locations", []), edits.extras.get("regions", [])
        try:
            again = sorted(made & set(index.preflight(locations, regions)))
        except (KeyError, ValueError) as exc:
            raise LevelError(f"step {n} ({step.build} {step.spec}) names an entry the index refuses: {exc}") from exc
        if again:
            raise LevelError(f"step {n} ({step.build} {step.spec}) names {again}, which an earlier step made")
        if differ := _differences(index, locations, regions):
            raise LevelError(f"step {n} ({step.build} {step.spec}) differs from world_index.json: {'; '.join(differ)}")
        result = edits.apply(bridge)
        if not result.ok:
            raise LevelError(f"step {n} ({step.build} {step.spec}) failed: {result.errors[0]}")
        index.register(locations, regions, replace=True)
        made.update(e["name"] for e in (*locations, *regions))


def mines_config_path() -> Path:
    """RiftalMines' ``config.yml`` in ``RIFTAL_GAME_DIR``, else in the riftal-game checkout beside this repository."""
    game = os.environ.get("RIFTAL_GAME_DIR")
    return (Path(game) if game else PROJECT_ROOT.parents[1] / "riftal-game") / MINES_CONFIG


def check_mine_gate(recipe: Recipe, specs: list[checks_mod.CheckSpec], mines_config: Path) -> None:
    """A world ``mines`` resets is built only with a zone-tagged ``mine_valid`` on a spec one of its ``mine`` steps builds (ADR 014 item 7).

    Without the world list no zone can be told apart from one ``mines`` resets, so every zone is refused.
    """
    try:
        worlds = yaml.safe_load(mines_config.read_text(encoding="utf-8"))["worlds"]
        if not isinstance(worlds, dict):
            raise TypeError(f"worlds is a {type(worlds).__name__}, not a mapping")
    except (OSError, yaml.YAMLError, KeyError, TypeError) as exc:
        raise LevelError(f"cannot read the mines world list {mines_config}: {exc!r}; no zone is built without it") from exc
    if recipe.zone not in worlds:
        return
    built = {step.spec for step in recipe.steps if step.build == "mine"}
    if not any(s.kind == "mine_valid" and s.zone == recipe.zone and s.args["spec"] in built for s in specs):
        raise LevelError(
            f"{mines_config} lists {recipe.zone!r}, but checks.yaml has no mine_valid with zone {recipe.zone!r}"
            f" on a spec a mine step of the recipe builds {sorted(built)}"
        )


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


def _run_checks(bridge: Bridge, recipe: Recipe, index: WorldIndex, all_specs: list[checks_mod.CheckSpec]) -> None:
    specs = [s for s in all_specs if s.zone == recipe.zone]
    if not specs:
        raise LevelError(f"checks.yaml has no check with zone {recipe.zone!r}; a zone is not built unchecked")
    worlds = [(s.id, checks_mod.check_world(index, s)) for s in specs]
    # A mistyped name must refuse the build rather than drop the check out of the gate.
    if unresolved := [i for i, world in worlds if world is None]:
        raise LevelError(f"checks.yaml has checks on {recipe.zone!r} naming nothing the built index resolves: {unresolved}")
    if elsewhere := [f"{i} reads {world!r}" for i, world in worlds if world != recipe.zone]:
        raise LevelError(f"checks.yaml has checks on {recipe.zone!r} that read another world: {elsewhere}")
    # scan() refuses every finding, a stricter test than offdisk_clear, so running it here would only scan the zone twice.
    if failed := checks_mod.run_checks(bridge, index, [s for s in specs if s.kind != "offdisk_clear"]).failed:
        raise LevelError(f"{recipe.zone!r} failed {[f'{r.id}: {r.detail}' for r in failed]}")


def build_level(
    bridge: Bridge, zone: str, after_stop: Callable[[], Saved], *, root: Path = PROJECT_ROOT,
    index: WorldIndex | None = None, checks_path: Path | None = None, mines_config: Path | None = None,
) -> Path:
    """Build ``zone`` on the server behind ``bridge`` and write its lock; the name, index and mine gate are checked before any call."""
    recipe = load_recipe(zone, root)
    # The build registers its steps' names into its own copy, never into the caller's index or the committed file.
    index = WorldIndex.load() if index is None else copy.deepcopy(index)
    check_index(recipe, index)
    specs = checks_mod.load_checks(checks_path)
    check_mine_gate(recipe, specs, mines_config_path() if mines_config is None else mines_config)
    inputs = input_hashes(recipe, root)
    for tile in pregen_bounds(recipe.bounds).tiles():
        bridge.call_job("pregen", world=zone, bounds=tile.to_json())
    _run_steps(bridge, recipe, root, index)
    _run_checks(bridge, recipe, index, specs)
    chunks = scan(bridge, zone)
    region = fetch_region(bridge, zone, recipe.bounds)
    if flowers := chorus_outside(region, recipe, root):
        raise LevelError(f"{zone!r} has {len(flowers)} chorus flower(s) outside every mine interior, first at {flowers[0]}")
    saved = after_stop()
    lock = {
        "zone": zone, "generator": recipe.generator, "seed": recipe.seed, "bounds": recipe.bounds.to_json(),
        "core_image": saved.core_image, "designbridge_commit": saved.designbridge_commit,
        "toolkit_commit": saved.toolkit_commit, "inputs": inputs, "chunks": chunks, "size_bytes": saved.size_bytes,
        "content_sha256": content_sha256(region, saved.npcs, saved.texts),
    }
    path = root / "levels" / f"{zone}.lock.json"
    path.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    return path
