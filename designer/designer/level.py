"""A zone level built from its committed recipe, and the lock that names what was built (ADR 009).

``build_level`` drives the bridge of a throwaway server whose default world is the
zone: ``pregen``, the recipe's steps, the zone's checks, ``scan_items`` and the
block fingerprint. It then hands over to ``after_stop``, which stops that server and
reports what only the saved folder and the engine know, and writes the lock last,
so a failure anywhere leaves no lock behind. The recipe and lock formats are in
``levels/README.md``.
"""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from designer import checks as checks_mod
from designer.bridge import Bridge
from designer.builders import BUILDERS
from designer.builders.base import Palette
from designer.config import PROJECT_ROOT
from designer.palettes import load_palettes
from designer.region import Bounds, Bounds2D, Region, fetch_heightmap, fetch_region
from designer.world_index import WorldIndex

ZONE_RE = re.compile(r"^[a-z0-9_]+$")
# The guard protects paths holding these words, and a build volume is named after
# its zone, so a zone carrying one would make its own volume unremovable (ADR 007 item 3).
FORBIDDEN_WORDS = ("world", "player", "backup")


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


def _run_steps(bridge: Bridge, recipe: Recipe, root: Path) -> None:
    def fetch(world: str, bounds: Bounds2D) -> Any:
        return fetch_heightmap(bridge, world, bounds)

    for n, step in enumerate(recipe.steps):
        spec = json.loads(_input(root, step.spec).read_text(encoding="utf-8"))
        edits = BUILDERS[step.build](spec, Palette.load(step.palette), fetch)
        if edits.world != recipe.zone:
            raise LevelError(f"step {n} writes world {edits.world!r}, not the zone {recipe.zone!r}")
        result = edits.apply(bridge)
        if not result.ok:
            raise LevelError(f"step {n} ({step.build} {step.spec}) failed: {result.errors[0]}")


def _run_checks(bridge: Bridge, recipe: Recipe, index: WorldIndex, checks_path: Path | None) -> None:
    specs = [s for s in checks_mod.load_checks(checks_path) if checks_mod.check_world(index, s) == recipe.zone]
    if not specs:
        raise LevelError(f"checks.yaml has no check on {recipe.zone!r}; a zone is not built unchecked")
    if failed := checks_mod.run_checks(bridge, index, specs).failed:
        raise LevelError(f"{recipe.zone!r} failed {[f'{r.id}: {r.detail}' for r in failed]}")


def build_level(
    bridge: Bridge, zone: str, after_stop: Callable[[], Saved], *, root: Path = PROJECT_ROOT,
    index: WorldIndex | None = None, checks_path: Path | None = None,
) -> Path:
    """Build ``zone`` on the server behind ``bridge`` and write its lock; the name and index are checked before any call."""
    recipe = load_recipe(zone, root)
    index = WorldIndex.load() if index is None else index
    check_index(recipe, index)
    inputs = input_hashes(recipe, root)
    for tile in pregen_bounds(recipe.bounds).tiles():
        bridge.call_job("pregen", world=zone, bounds=tile.to_json())
    _run_steps(bridge, recipe, root)
    _run_checks(bridge, recipe, index, checks_path)
    chunks = scan(bridge, zone)
    region = fetch_region(bridge, zone, recipe.bounds)
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
