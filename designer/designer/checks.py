"""``checks.yaml`` bound to the index: one fetch per world, every check run, a markdown report."""

from __future__ import annotations

import json
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np
import yaml

from designer.bridge import Bridge
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT, REPORTS_DIR
from designer.coords import int_coord, whole_int
from designer.custody import offdisk_clear
from designer.region import Bounds, LightRegion, Region, fetch_light, fetch_region
from designer.verify import MARGIN_Y, WALK_SPEED, Check, Pos, entity_clear, light_ok, mine_valid, no_holes, path_exists
from designer.verify import region_inside, travel_time, warp_safe
from designer.world_index import NAME_RE, NamedRegion, WorldIndex, resolve_at

VERSION = 1
DEFAULT_PATH = PROJECT_ROOT / "checks.yaml"
DEFAULTS = {"max_seconds": 10, "walk_speed": WALK_SPEED, "corridor_margin": 16}

# Per kind: the parameters a check must name, the optional ones filled from ``defaults``, and the optional ones
# its runner defaults itself. Any other key is refused, so a misspelling cannot run the check on a default.
KINDS: dict[str, tuple[tuple[str, ...], dict[str, str], tuple[str, ...]]] = {
    "path_exists": (("from", "to"), {"margin": "corridor_margin"}, ("max_drop",)),
    "travel_time": (
        ("from", "to"), {"margin": "corridor_margin", "speed": "walk_speed", "max_seconds": "max_seconds"}, ("max_drop",),
    ),
    "warp_safe": (("at",), {}, ()),
    "entity_clear": (("at",), {}, ()),
    "region_inside": (("inner", "outer"), {}, ()),
    "light_ok": (("region", "min_level"), {}, ("kind",)),
    "no_holes": (("region", "floor_y"), {}, ("inset",)),
    "mine_valid": (("region", "spec"), {}, ()),
    "offdisk_clear": (("world",), {}, ()),
}
SAFETY_SIZE = (7, 7, 7)


@dataclass(frozen=True)
class CheckSpec:
    id: str
    kind: str
    args: dict[str, Any]
    zone: str | None = None


@dataclass
class CheckResult:
    id: str
    check: str
    ok: bool
    detail: str
    coords: list[Pos] = field(default_factory=list)
    seconds: float = 0.0


@dataclass
class Report:
    results: list[CheckResult]
    started: datetime

    @property
    def failed(self) -> list[CheckResult]:
        return [r for r in self.results if not r.ok]


@dataclass(frozen=True)
class Fetch:
    bounds: Bounds
    light: bool = False


def load_checks(path: Path | None = None) -> list[CheckSpec]:
    """Every check in the file with its defaults filled in and an id, or ``ValueError`` naming the first bad entry."""
    path = DEFAULT_PATH if path is None else Path(path)
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if data.get("version") != VERSION:
        raise ValueError(f"{path} is version {data.get('version')!r}; this toolkit reads version {VERSION}")
    defaults, specs, seen = {**DEFAULTS, **(data.get("defaults") or {})}, [], set()
    for n, entry in enumerate(data.get("checks") or []):
        kind = entry.get("check") if isinstance(entry, dict) else None
        if kind not in KINDS:
            raise ValueError(f"check {n}: kind must be one of {sorted(KINDS)}, got {kind!r}")
        required, optional, own = KINDS[kind]
        zone = entry.get("zone")
        if zone is not None and not NAME_RE.fullmatch(str(zone)):
            raise ValueError(f"check {n} ({kind}): zone must match {NAME_RE.pattern}, got {zone!r}")
        args = {k: v for k, v in entry.items() if k not in ("check", "id", "zone")}
        reads = [*required, *optional, *own]
        if unknown := [k for k in args if k not in reads]:
            raise ValueError(f"check {n} ({kind}) has unknown keys {unknown}; it reads {reads}")
        if missing := [k for k in required if k not in args]:
            raise ValueError(f"check {n} ({kind}) is missing {missing}")
        for key, source in optional.items():
            args.setdefault(key, defaults[source])
        check_id = entry.get("id") or "_".join([kind, *(str(args[k]) for k in required if NAME_RE.fullmatch(str(args[k])))])
        if check_id in seen:
            raise ValueError(f"check {n} duplicates id {check_id!r}; give one of them an explicit id")
        seen.add(check_id)
        specs.append(CheckSpec(str(check_id), kind, args, None if zone is None else str(zone)))
    return specs


def _at(index: WorldIndex, ref: Any) -> tuple[str, Pos]:
    world, (x, y, z) = resolve_at(index, str(ref))
    if y is None:
        raise ValueError(f"{ref!r} names no y")
    return world, (x, y, z)


def _region(index: WorldIndex, name: Any) -> NamedRegion:
    entry = index.resolve(str(name))
    if not isinstance(entry, NamedRegion):
        raise ValueError(f"{name!r} is a location, not a region")
    return entry


def _ends(index: WorldIndex, args: dict[str, Any]) -> tuple[str, Pos, Pos, Bounds]:
    (world, a), (other, b) = _at(index, args["from"]), _at(index, args["to"])
    if world != other:
        raise ValueError(f"{args['from']!r} is in {world!r} but {args['to']!r} is in {other!r}")
    return world, a, b, Bounds(a, b).expand(_margin(args), "xz").expand(MARGIN_Y, "y")


def _margin(args: dict[str, Any]) -> int:
    return whole_int(args["margin"], "margin must be an integer")


def _max_drop(args: dict[str, Any]) -> int:
    return whole_int(args.get("max_drop", 1), "max_drop must be an integer")


def _mine_spec(args: dict[str, Any]) -> MineSpec:
    path = PROJECT_ROOT / str(args["spec"])
    if not path.is_file():
        raise ValueError(f"mine spec {path} does not exist")
    return MineSpec.from_dict(json.loads(path.read_text(encoding="utf-8")))


def _needs(index: WorldIndex, spec: CheckSpec) -> tuple[str, Bounds, bool] | None:
    """The world, the blocks and whether light is wanted for one check; ``None`` when it reads no blocks."""
    if spec.kind in ("path_exists", "travel_time"):
        world, _, _, box = _ends(index, spec.args)
        return world, box, False
    if spec.kind in ("warp_safe", "entity_clear"):
        world, pos = _at(index, spec.args["at"])
        return world, Bounds.from_center(pos, SAFETY_SIZE), False
    if spec.kind in ("region_inside", "offdisk_clear"):
        return None
    named = _region(index, spec.args["region"])
    if spec.kind == "mine_valid":
        geo = _mine_spec(spec.args).geometry()
        return named.world, geo.padding.union(geo.exit_platform), False
    return named.world, named.bounds if spec.kind == "light_ok" else named.bounds.expand(1), spec.kind == "light_ok"


def check_world(index: WorldIndex, spec: CheckSpec) -> str | None:
    """The world a check reads, or ``None`` when a name it needs does not resolve."""
    try:
        need = _needs(index, spec)
        if need is not None:
            return need[0]
        if spec.kind == "offdisk_clear":
            return index.world(str(spec.args["world"])).name
        return _region(index, spec.args["inner"]).world
    except (KeyError, ValueError):
        return None


def plan_fetches(checks: Iterable[CheckSpec], index: WorldIndex) -> dict[str, Fetch]:
    """One union per world of everything the checks read; a check that names nothing resolvable is left to fail at run time."""
    plan: dict[str, Fetch] = {}
    for spec in checks:
        try:
            need = _needs(index, spec)
        except (KeyError, ValueError):
            continue
        if need is not None:
            world, box, light = need
            have = plan.get(world)
            plan[world] = Fetch(box if have is None else have.bounds.union(box), light or (have is not None and have.light))
    return plan


def plan_scans(checks: Iterable[CheckSpec], index: WorldIndex) -> set[str]:
    """Each indexed world an ``offdisk_clear`` names, scanned once however many read it; an unindexed one fails at run time."""
    worlds = (check_world(index, spec) for spec in checks if spec.kind == "offdisk_clear")
    return {world for world in worlds if world is not None}


@dataclass
class RunContext:
    """Each world's union fetched once; every check reads a ``sub`` view of it, light over the same cells as its blocks."""

    regions: dict[str, Region]
    lights: dict[str, LightRegion] = field(default_factory=dict)
    scans: dict[str, list[dict[str, Any]]] = field(default_factory=dict)

    @classmethod
    def fetch(cls, bridge: Bridge, plan: dict[str, Fetch], scans: Iterable[str] = ()) -> RunContext:
        regions = {world: fetch_region(bridge, world, f.bounds) for world, f in plan.items()}
        lights = {world: fetch_light(bridge, world, f.bounds) for world, f in plan.items() if f.light}
        findings = {world: bridge.call_job("scan_items", world=world)["result"]["findings"] for world in sorted(scans)}
        return cls(regions, lights, findings)

    def findings(self, world: str) -> list[dict[str, Any]]:
        if world not in self.scans:
            raise ValueError(f"world {world!r} was never scanned")
        return self.scans[world]

    def _whole(self, world: str) -> Region:
        if world not in self.regions:
            raise ValueError(f"nothing was fetched from world {world!r}")
        return self.regions[world]

    def region(self, world: str, bounds: Bounds) -> Region:
        return self._whole(world).sub(bounds)

    def light(self, world: str, bounds: Bounds) -> LightRegion:
        if world not in self.lights:
            raise ValueError(f"no light was fetched from world {world!r}")
        whole = self.lights[world]
        at = whole.bounds.slices(bounds)
        return LightRegion(world, bounds, whole.block[at], whole.sky[at], whole.stale_chunks)

    def around(self, world: str, pos: Pos) -> Region:
        """The ``SAFETY_SIZE`` box about ``pos``, or ``ValueError`` naming the position when it was never fetched."""
        box = self._whole(world).bounds
        if not box.contains(pos):
            raise ValueError(f"{pos} is outside the fetched {box.min}..{box.max}")
        return self.region(world, Bounds.from_center(pos, SAFETY_SIZE))


def _run_path(ctx: RunContext, index: WorldIndex, args: dict[str, Any]) -> Check:
    world, a, b, box = _ends(index, args)
    return path_exists(ctx.region(world, box), a, b, margin=_margin(args), max_drop=_max_drop(args))


def _run_travel(ctx: RunContext, index: WorldIndex, args: dict[str, Any]) -> Check:
    world, a, b, box = _ends(index, args)
    speed, limit = float(args["speed"]), float(args["max_seconds"])
    found = travel_time(ctx.region(world, box), a, b, speed=speed, margin=_margin(args), max_drop=_max_drop(args))
    if found.ok and found.seconds > limit:
        found.ok, found.detail, found.coords = False, f"{found.detail}, over {limit:g} s", found.path[-1:]
    return found


def _run_safety(fn: Callable[[Region, Pos], Check]) -> Callable[[RunContext, WorldIndex, dict[str, Any]], Check]:
    def run(ctx: RunContext, index: WorldIndex, args: dict[str, Any]) -> Check:
        world, pos = _at(index, args["at"])
        return fn(ctx.around(world, pos), pos)
    return run


def _run_inside(ctx: RunContext, index: WorldIndex, args: dict[str, Any]) -> Check:
    return region_inside(_region(index, args["inner"]).bounds, _region(index, args["outer"]).bounds)


def _run_light(ctx: RunContext, index: WorldIndex, args: dict[str, Any]) -> Check:
    named = _region(index, args["region"])
    view = ctx.region(named.world, named.bounds)
    light = ctx.light(named.world, view.bounds)
    min_level = whole_int(args["min_level"], "min_level must be an integer")
    return light_ok(light, min_level, mask=view.passable(), kind=str(args.get("kind", "block")))


def _inset(named: NamedRegion, args: dict[str, Any]) -> Bounds:
    """The region shrunk by ``inset`` on each side in x and z, so a room's own walls are not read as its floor."""
    inset = whole_int(args.get("inset", 0), "inset must be an integer")
    if inset < 0:
        raise ValueError(f"inset must be at least 0, got {inset}")
    box = named.bounds
    if any(2 * inset >= box.size[a] for a in (0, 2)):
        raise ValueError(f"inset {inset} leaves nothing of {named.name!r}'s {box.size[0]}x{box.size[2]} footprint")
    return box.expand(-inset, "xz")


def _run_holes(ctx: RunContext, index: WorldIndex, args: dict[str, Any]) -> Check:
    named = _region(index, args["region"])
    view = ctx.region(named.world, _inset(named, args).expand(1, "y"))
    return no_holes(view, int_coord(args["floor_y"], "floor_y must be an integer"), np.ones(view.bounds.shape[1:], dtype=bool))


def _run_mine(ctx: RunContext, index: WorldIndex, args: dict[str, Any]) -> Check:
    named, spec = _region(index, args["region"]), _mine_spec(args)
    geo = spec.geometry()
    return mine_valid(ctx.region(named.world, geo.padding.union(geo.exit_platform)), spec)


def _run_offdisk(ctx: RunContext, index: WorldIndex, args: dict[str, Any]) -> Check:
    return offdisk_clear(ctx.findings(index.world(str(args["world"])).name))


CHECK_RUNNERS: dict[str, Callable[[RunContext, WorldIndex, dict[str, Any]], Check]] = {
    "path_exists": _run_path, "travel_time": _run_travel, "warp_safe": _run_safety(warp_safe),
    "entity_clear": _run_safety(entity_clear), "region_inside": _run_inside, "light_ok": _run_light,
    "no_holes": _run_holes, "mine_valid": _run_mine, "offdisk_clear": _run_offdisk,
}


def run_one(ctx: RunContext, index: WorldIndex, spec: CheckSpec) -> CheckResult:
    """One check as a result; a name that does not resolve, a position never fetched or a missing spec file fails it."""
    start = time.perf_counter()
    try:
        found = CHECK_RUNNERS[spec.kind](ctx, index, spec.args)
    except (KeyError, ValueError) as exc:
        found = Check(False, str(exc.args[0]) if isinstance(exc, KeyError) and exc.args else str(exc))
    return CheckResult(spec.id, spec.kind, found.ok, found.detail, list(found.coords), time.perf_counter() - start)


def run_checks(bridge: Bridge, index: WorldIndex, checks: Iterable[CheckSpec], *, only: Iterable[str] | None = None) -> Report:
    """Fetch every world's union once, run the checks, or those whose id is in ``only``, and report."""
    checks = list(checks)
    if only is not None:
        wanted = set(only)
        if unknown := wanted - {c.id for c in checks}:
            raise ValueError(f"no such check {sorted(unknown)}")
        checks = [c for c in checks if c.id in wanted]
    started = datetime.now(UTC)
    ctx = RunContext.fetch(bridge, plan_fetches(checks, index), plan_scans(checks, index))
    return Report([run_one(ctx, index, spec) for spec in checks], started)


def write_report(report: Report, path: Path | None = None) -> Path:
    """The report as markdown: counts, one row per check, then every failure with its coordinates."""
    path = REPORTS_DIR / f"checks-{report.started:%Y%m%d-%H%M%S}.md" if path is None else Path(path)
    failed = report.failed
    lines = [
        f"# Checks {report.started.isoformat(timespec='seconds')}", "",
        f"{len(report.results) - len(failed)} passed, {len(failed)} failed of {len(report.results)}.", "",
        "| id | check | ok | seconds | detail |", "|---|---|---|---|---|",
        *(f"| {r.id} | {r.check} | {'yes' if r.ok else 'no'} | {r.seconds:.2f} | {r.detail} |" for r in report.results),
    ]
    if failed:
        lines += ["", "## Failures"]
        for r in failed:
            lines += ["", f"### {r.id}", "", r.detail, *(f"- {x}, {y}, {z}" for x, y, z in r.coords)]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return path
