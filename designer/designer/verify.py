"""Standing, pathing, travel time, light, floor and mine checks over a ``Region``. Pure numpy, no server."""

from __future__ import annotations

import heapq
import math
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from designer.blocks import BlockClass, format_name, parse_name
from designer.builders.mine_spec import SIDES, MineSpec
from designer.region import Bounds, LightRegion, Region

# Bedrock player speeds on level ground, blocks per second.
WALK_SPEED = 4.317
SPRINT_SPEED = 5.612

# A default corridor grows the endpoints' bounding box this far in y. A route
# rarely climbs or drops more than a few storeys between two points that a
# check names together, and every extra layer is another plane of nodes.
MARGIN_Y = 8

# Move costs in blocks: a step up is a jump, a drop is a short fall.
STEP_UP = 0.5
DROP = 0.25

# Blocks below the feet within which a warp must find solid ground.
LANDING = 3

# A cell and its eight neighbours, as ``(dz, dx)``.
RING = [(dz, dx) for dz in (-1, 0, 1) for dx in (-1, 0, 1)]

# How many offending cells a whole-region check names: enough to see the
# shape of the problem, few enough to read.
LIGHT_WORST = 20
HOLES_REPORTED = 50
LEAKS_REPORTED = 20

LIGHT_KINDS = ("block", "sky", "max")

Pos = tuple[int, int, int]


@dataclass
class Check:
    ok: bool
    detail: str
    coords: list[Pos] = field(default_factory=list)
    data: dict[str, Any] = field(default_factory=dict)


@dataclass
class PathResult(Check):
    """``path`` is world ``(x, y, z)`` per step, ``length`` its cost in blocks, ``explored`` the closed nodes."""

    path: list[Pos] = field(default_factory=list)
    length: float = 0.0
    explored: int = 0


@dataclass
class TravelResult(Check):
    seconds: float = 0.0
    blocks: float = 0.0
    path: list[Pos] = field(default_factory=list)


@dataclass
class MineResult(Check):
    """``leaks`` are padding cells the interior reaches; ``composition`` observed fractions; ``deviations`` their distance from the spec."""

    leaks: list[Pos] = field(default_factory=list)
    entrances_found: int = 0
    composition: dict[str, float] = field(default_factory=dict)
    deviations: dict[str, float] = field(default_factory=dict)


def stand_mask(region: Region) -> np.ndarray:
    """Bool ``[y][z][x]``: a player can stand with feet in the cell. See ``Region.stand_mask``."""
    return region.stand_mask()


def _block(pos: Sequence[float]) -> Pos:
    """World ``(x, y, z)`` of the block ``pos`` falls in.

    Each coordinate is floored, because block ``n`` spans ``[n, n + 1)``, so
    ``-0.5`` is in block ``-1``. ``int()`` truncates toward zero, which is the
    wrong block for every negative fraction.
    """
    x, y, z = (math.floor(v) for v in pos)
    return x, y, z


def _snap(mask: np.ndarray, bounds: Bounds, pos: Sequence[float], radius: int) -> tuple[int, int, int] | None:
    """Local ``(iy, iz, ix)`` of the nearest standable cell within Chebyshev ``radius`` of the block ``pos`` is in."""
    ix, iy, iz = (p - lo for p, lo in zip(_block(pos), bounds.min, strict=True))
    lo = tuple(max(i - radius, 0) for i in (iy, iz, ix))
    hi = tuple(min(i + radius, n - 1) for i, n in zip((iy, iz, ix), mask.shape))
    if any(a > b for a, b in zip(lo, hi)):
        return None
    hits = np.argwhere(mask[lo[0]:hi[0] + 1, lo[1]:hi[1] + 1, lo[2]:hi[2] + 1]) + lo
    if not len(hits):
        return None
    nearest = hits[int(((hits - (iy, iz, ix)) ** 2).sum(axis=1).argmin())]
    return int(nearest[0]), int(nearest[1]), int(nearest[2])


def _world(box: Bounds, local: Sequence[int]) -> Pos:
    iy, iz, ix = (int(v) for v in local)
    return ix + box.min[0], iy + box.min[1], iz + box.min[2]


def path_exists(
    region: Region, a: Sequence[float], b: Sequence[float], *,
    max_nodes: int = 200_000, corridor: Bounds | None = None, margin: int = 16,
    max_drop: int = 1, snap_radius: int = 2,
) -> PathResult:
    """A* from ``a`` to ``b`` over standable cells, four horizontal moves, up one, down ``max_drop``.

    Both ends snap to the nearest standable cell within ``snap_radius``. The
    search covers ``corridor``, or the endpoints' box grown by ``margin`` in x
    and z, clipped to the region. Costs are 1.0 per horizontal move plus
    ``STEP_UP`` per block climbed and ``DROP`` per block fallen, and the
    heuristic charges the same per-block rates so it never overestimates.
    """
    mask = stand_mask(region)
    start = _snap(mask, region.bounds, a, snap_radius)
    if start is None:
        return PathResult(False, "start not standable", [_block(a)])
    goal = _snap(mask, region.bounds, b, snap_radius)
    if goal is None:
        return PathResult(False, "goal not standable", [_block(b)])
    start_w, goal_w = _world(region.bounds, start), _world(region.bounds, goal)
    if corridor is None:
        corridor = Bounds(start_w, goal_w).expand(margin, "xz").expand(MARGIN_Y, "y")
    box = region.bounds.intersect(corridor)
    data: dict[str, Any] = {"start": start_w, "goal": goal_w, "corridor": box.to_json() if box else None}
    if box is None or not (box.contains(start_w) and box.contains(goal_w)):
        return PathResult(False, "no path", [], data)

    at = region.bounds.slices(box)
    ny, nz, nx = box.shape
    plane = nz * nx
    stand = mask[at].ravel().tolist()
    passable = region.passable()[at].ravel().tolist()
    g = np.full(ny * plane, np.inf, dtype=np.float32)
    closed = np.zeros(ny * plane, dtype=bool)
    parent = np.full(ny * plane, -1, dtype=np.int32)
    (sy, sz, sx), (gy, gz, gx) = box.local(start_w), box.local(goal_w)
    s, t = (sy * nz + sz) * nx + sx, (gy * nz + gz) * nx + gx

    def h(y: int, z: int, x: int) -> float:
        dy = gy - y
        return abs(gx - x) + abs(gz - z) + (STEP_UP * dy if dy > 0 else -DROP * dy)

    g[s] = 0.0
    heap = [(h(sy, sz, sx), s)]
    explored = 0
    detail = "no path"
    while heap:
        _, cur = heapq.heappop(heap)
        if closed[cur]:
            continue
        if cur == t:
            path = []
            while cur >= 0:
                y, rest = divmod(cur, plane)
                path.append(_world(box, (y, *divmod(rest, nx))))
                cur = int(parent[cur])
            path.reverse()
            return PathResult(True, "path found", [], data, path=path, length=float(g[t]), explored=explored)
        closed[cur] = True
        explored += 1
        if explored >= max_nodes:
            detail = "node cap reached"
            break
        y, rest = divmod(cur, plane)
        z, x = divmod(rest, nx)
        base = float(g[cur])
        for dz, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            z2, x2 = z + dz, x + dx
            if not (0 <= z2 < nz and 0 <= x2 < nx):
                continue
            col = z2 * nx + x2
            steps = [(y, base + 1.0)]
            if y + 2 < ny and passable[(y + 2) * plane + z * nx + x]:
                steps.append((y + 1, base + 1.0 + STEP_UP))
            # The head enters the neighbour column before the feet leave the ledge.
            if passable[(y + 1) * plane + col]:
                for d in range(1, max_drop + 1):
                    if y - d < 1 or not passable[(y - d + 1) * plane + col]:
                        break
                    steps.append((y - d, base + 1.0 + DROP * d))
                    if stand[(y - d) * plane + col]:
                        break
            for y2, cost in steps:
                nb = y2 * plane + col
                if stand[nb] and not closed[nb] and cost < g[nb]:
                    g[nb] = cost
                    parent[nb] = cur
                    heapq.heappush(heap, (cost + h(y2, z2, x2), nb))

    seen = np.flatnonzero(closed)
    ys, rest = np.divmod(seen, plane)
    zs, xs = np.divmod(rest, nx)
    order = np.argsort((ys - gy) ** 2 + (zs - gz) ** 2 + (xs - gx) ** 2, kind="stable")[:5]
    hints = [_world(box, (int(ys[i]), int(zs[i]), int(xs[i]))) for i in order]
    return PathResult(False, detail, hints, data, explored=explored)


def travel_time(
    region: Region, a: Sequence[float], b: Sequence[float], *, speed: float = WALK_SPEED, **path_kwargs: Any
) -> TravelResult:
    """Seconds to walk the cheapest path from ``a`` to ``b`` at ``speed`` blocks per second."""
    if speed <= 0:
        raise ValueError(f"speed must be positive, got {speed}")
    found = path_exists(region, a, b, **path_kwargs)
    if not found.ok:
        return TravelResult(False, found.detail, found.coords, found.data)
    seconds = found.length / speed
    return TravelResult(
        True, f"{found.length:.2f} blocks in {seconds:.2f} s", [], found.data,
        seconds=seconds, blocks=found.length, path=found.path,
    )


def _solid_within(classes: np.ndarray, iy: int, iz: int, ix: int, n: int) -> bool:
    """A solid block among the ``n`` cells from ``(iy, iz, ix)`` downward; cells below the region count as not solid."""
    return bool((classes[max(iy - n + 1, 0):iy + 1, iz, ix] == BlockClass.SOLID).any())


def entity_clear(region: Region, pos: Sequence[float]) -> Check:
    """A 1x2 hitbox with its feet at ``pos`` is free and whatever it rests on is walkable.

    Feet and head must be passable. The support is the first block below the
    feet that is neither air nor passable, and it must be solid, because a
    player over liquid sinks and over danger burns. A column with no support
    inside the region obstructs nothing here; ``warp_safe`` is the check that
    demands a landing. ``coords`` names the offending cells. A fractional
    ``pos`` means the block it falls in, each coordinate floored. ``pos``
    outside the region is a failed check, not a crash, for a caller that did
    not fetch around it first.
    """
    at = _block(pos)
    if not region.bounds.contains(at):
        return Check(False, f"{at} is outside the fetched region {region.bounds.min}..{region.bounds.max}", [at])
    iy, iz, ix = region.bounds.local(at)
    x, y, z = at
    classes, passable = region.classes(), region.passable()
    blocked = [(x, y + d, z) for d in (0, 1) if iy + d < classes.shape[0] and not passable[iy + d, iz, ix]]
    if blocked:
        return Check(False, "hitbox blocked", blocked)
    support = np.flatnonzero(~passable[:iy, iz, ix])
    if len(support):
        top = int(support[-1])
        kind = BlockClass(int(classes[top, iz, ix]))
        if kind != BlockClass.SOLID:
            return Check(False, f"floor is {kind.name.lower()}", [(x, y - (iy - top), z)])
    return Check(True, "clear")


def warp_safe(region: Region, pos: Sequence[float]) -> Check:
    """``entity_clear`` at ``pos``, plus a landing a warp can drop a player onto.

    In order: the hitbox check; a solid block within ``LANDING`` blocks below
    the feet, so a warp over a hole or a void column is refused; no liquid or
    danger in the 3x3 at floor, feet or head level, because the first step off
    the warp goes in any direction and a lava floor is the same death as a
    lava wall; and no cell in the 3x3 at floor level that is a hole deeper
    than ``LANDING``, so that step cannot be a fall either.
    ``detail`` names the first rule that fails and ``coords`` the cells that
    break it. Cells outside the region are unknown: they never offend, and
    they never count as solid. ``pos`` itself outside the region is a failed
    check, not a crash: a warp target is often hand-typed, and a fetch that
    missed it by a block is exactly the case this check exists to catch.
    """
    clear = entity_clear(region, pos)
    if not clear.ok:
        return clear
    x, y, z = at = _block(pos)
    iy, iz, ix = region.bounds.local(at)
    classes = region.classes()
    ny, nz, nx = classes.shape
    if not _solid_within(classes, iy - 1, iz, ix, LANDING):
        return Check(False, f"no solid within {LANDING} below", [(x, y - 1, z)])
    around = [(dz, dx) for dz, dx in RING if 0 <= iz + dz < nz and 0 <= ix + dx < nx]
    hazards = [
        (x + dx, y + dy, z + dz)
        for dy in (-1, 0, 1) if 0 <= iy + dy < ny
        for dz, dx in around
        if classes[iy + dy, iz + dz, ix + dx] in (BlockClass.LIQUID, BlockClass.DANGER)
    ]
    if hazards:
        return Check(False, "liquid or danger beside the hitbox", hazards)
    holes = [
        (x + dx, y - 1, z + dz)
        for dz, dx in around
        if (dz, dx) != (0, 0) and not _solid_within(classes, iy - 1, iz + dz, ix + dx, LANDING + 1)
    ]
    if holes:
        return Check(False, f"hole deeper than {LANDING} in the floor ring", holes)
    return Check(True, "warp safe")


def light_ok(light: LightRegion, min_level: int, *, mask: np.ndarray | None = None, kind: str = "block") -> Check:
    """Every checked cell has ``kind`` light of at least ``min_level``.

    ``mask`` is bool ``[y][z][x]`` naming the cells to check, every cell when
    ``None``; pass a region's ``passable()`` to skip the inside of walls. The
    mask must come from a region fetched over the same bounds as the light,
    since only its shape is checked and a same-shaped mask from other bounds
    would silently check the wrong cells.
    ``kind`` is ``block``, ``sky`` or ``max`` of the two. ``data`` carries the
    count ``below`` and its ``fraction`` of the checked cells; ``coords`` the
    ``LIGHT_WORST`` darkest cells, lowest level first.
    """
    if kind not in LIGHT_KINDS:
        raise ValueError(f"kind must be one of {LIGHT_KINDS}, got {kind!r}")
    if not 0 <= min_level <= 15:
        raise ValueError(f"min_level must be 0..15, got {min_level}")
    levels = {"block": light.block, "sky": light.sky, "max": np.maximum(light.block, light.sky)}[kind]
    checked = np.ones(levels.shape, dtype=bool) if mask is None else np.asarray(mask, dtype=bool)
    if checked.shape != levels.shape:
        raise ValueError(f"mask shape {checked.shape} does not match light shape {levels.shape}")
    dark = checked & (levels < min_level)
    below, total = int(dark.sum()), int(checked.sum())
    data = {"below": below, "fraction": below / total if total else 0.0}
    if not below:
        return Check(True, f"{kind} light at least {min_level}", [], data)
    hits = np.argwhere(dark)
    order = np.lexsort((hits[:, 2], hits[:, 1], hits[:, 0], levels[dark]))[:LIGHT_WORST]
    return Check(False, f"{below} of {total} cells below {kind} light {min_level}", [_world(light.bounds, hits[i]) for i in order], data)


def no_holes(region: Region, floor_y: int, walkway_mask: np.ndarray) -> Check:
    """Every walkway cell has a floor under ``floor_y`` and room to walk at it.

    ``walkway_mask`` is bool ``[z][x]`` over the region's footprint. A hole is a
    walkway cell whose block at ``floor_y - 1`` is not solid, or whose block at
    ``floor_y`` is not passable, so a missing floor block, a lava or water
    floor, a wall across the walkway and a puddle in it all count. ``coords``
    holds up to ``HOLES_REPORTED`` offending cells, the floor cell for a gap
    and the walkway cell for an obstruction; ``data`` the total.
    """
    y0, y1 = region.bounds.min[1], region.bounds.max[1]
    if not y0 < floor_y <= y1:
        raise ValueError(f"floor_y {floor_y} needs both {floor_y - 1} and {floor_y} inside y {y0}..{y1}")
    walkway = np.asarray(walkway_mask, dtype=bool)
    if walkway.shape != region.bounds.shape[1:]:
        raise ValueError(f"walkway mask shape {walkway.shape} does not match footprint {region.bounds.shape[1:]}")
    iy = floor_y - y0
    gap = walkway & (region.classes()[iy - 1] != BlockClass.SOLID)
    blocked = walkway & ~region.passable()[iy]
    holes = gap | blocked
    count = int(holes.sum())
    if not count:
        return Check(True, "no holes", [], {"holes": 0})
    coords = [
        _world(region.bounds, (iy - 1 if gap[iz, ix] else iy, iz, ix))
        for iz, ix in np.argwhere(holes)[:HOLES_REPORTED]
    ]
    return Check(False, f"{count} holes in the walkway", coords, {"holes": count})


def _flood(open_: np.ndarray, seed: tuple[Any, ...], stop: np.ndarray) -> np.ndarray:
    """Cells six-connected to the ``seed`` index of ``open_`` by dilation until stable; a ``stop`` cell is reached but never passed."""
    reach = np.zeros(open_.shape, dtype=bool)
    reach[seed] = True
    while True:
        front, grown = reach & ~stop, reach.copy()
        for axis in range(3):
            lo, hi = [slice(None)] * 3, [slice(None)] * 3
            lo[axis], hi[axis] = slice(1, None), slice(None, -1)
            grown[tuple(lo)] |= front[tuple(hi)]
            grown[tuple(hi)] |= front[tuple(lo)]
        grown &= open_
        if grown.sum() == reach.sum():
            return reach
        reach = grown


def _fractions(blocks: np.ndarray, names: list[str]) -> dict[str, float]:
    """Share of each canonical name among the non-air cells of ``blocks``."""
    counts = np.bincount(blocks[blocks != 0].ravel(), minlength=len(names))
    out: dict[str, float] = {}
    for name, share in zip(names, counts / max(int(counts.sum()), 1)):
        if share:
            out[name] = out.get(name, 0.0) + float(share)
    return out


def mine_valid(region: Region, spec: MineSpec, *, tolerance: float = 0.03) -> MineResult:
    """The mine in ``region`` is enclosed, opens only where declared, holds the declared ores and stands on a floor.

    Enclosure floods from the whole interior, passable since all of it gets mined, never through the entrance; a
    padding ring cell it reaches is a leak. The entrance must be passable through the whole wall, and any other
    passable surface component is undeclared; a component that also touches the entrance only contributes the
    cells outside it. Composition compares each block's share of the non-air interior to the normalised weights,
    per ore layer where given and ``ores`` elsewhere; an unnamed block deviates by its whole share and an empty
    band passes, so does a mined-out mine. The floor is solid under every interior column, and the exit platform
    is solid under its whole footprint with a clear cell above its walking lane, the centre line a player
    actually spawns and exits on, so a hand edit there is caught here rather than as a less specific failure
    from a check that walks out onto it. Furniture such as the lit posts down either side is outside the lane
    and never trips this rule. ``detail`` names every failing rule; ``coords`` holds leaks, undeclared cells,
    missing floor cells, missing platform cells, then blocked lane cells, ``LEAKS_REPORTED`` of each.
    """
    geo = spec.geometry()
    if region.world != spec.world:
        raise ValueError(f"region is from world {region.world!r}, spec names {spec.world!r}")
    covers = geo.padding.union(geo.exit_platform)
    if region.bounds.intersect(covers) != covers:
        raise ValueError(f"region {region.bounds.min}..{region.bounds.max} does not cover the padding and exit platform {covers.min}..{covers.max}")
    open_ = region.sub(geo.padding).passable().copy()
    open_[geo.padding.slices(geo.interior)] = True
    open_[geo.padding.slices(geo.entrance)] = False
    ring = np.ones(open_.shape, dtype=bool)
    ring[geo.padding.slices(geo.outer)] = False
    reach = _flood(open_, geo.padding.slices(geo.interior), ring) & ring
    leaks = [_world(geo.padding, at) for at in np.argwhere(reach)[:LEAKS_REPORTED]]

    shell = region.sub(geo.outer).passable()
    surface, opening = np.zeros(shell.shape, dtype=bool), np.zeros(shell.shape, dtype=bool)
    for axis in range(3):
        surface[tuple(0 if a == axis else slice(None) for a in range(3))] = True
        surface[tuple(-1 if a == axis else slice(None) for a in range(3))] = True
    opening[geo.outer.slices(geo.entrance)] = True
    entrance_ok = bool(shell[opening].all())
    left, components, undeclared = surface & shell, 0, []
    while left.any():
        part = _flood(left, tuple(np.argwhere(left)[0]), np.zeros(left.shape, dtype=bool))
        left, components = left & ~part, components + 1
        if (part & ~opening).any():
            undeclared.extend(_world(geo.outer, at) for at in np.argwhere(part & ~opening))

    inner = region.sub(geo.interior).blocks
    names = [format_name(*parse_name(name)) for name in region.palette]
    ys = np.arange(geo.interior.min[1], geo.interior.max[1] + 1)
    bands = [((ys >= l.y_from) & (ys <= l.y_to), l.ores, f"@{l.y_from}..{l.y_to}") for l in spec.ore_layers]
    bands.append((~np.logical_or.reduce([np.zeros(len(ys), dtype=bool), *(rows for rows, _, _ in bands)]), spec.ores, ""))
    deviations: dict[str, float] = {}
    for rows, ores, suffix in bands:
        observed, total = _fractions(inner[rows], names), sum(ores.values())
        for name in (observed.keys() | ores.keys()) if observed else ():
            deviations[name + suffix] = abs(observed.get(name, 0.0) - ores.get(name, 0.0) / total)

    _, zs, xs = region.bounds.slices(geo.interior)
    missing = region.classes()[spec.floor_y - 1 - region.bounds.min[1], zs, xs] != BlockClass.SOLID
    gaps = [_world(geo.interior, (-1, iz, ix)) for iz, ix in np.argwhere(missing)[:LEAKS_REPORTED]]

    door_axis, _ = SIDES[spec.entrance.side]
    lateral = 2 if door_axis == "x" else 0
    centre = (geo.exit_platform.min[lateral] + geo.exit_platform.max[lateral] + 1) // 2
    lane_min, lane_max = list(geo.exit_platform.min), list(geo.exit_platform.max)
    lane_min[lateral] = lane_max[lateral] = centre
    lane = Bounds(tuple(lane_min), tuple(lane_max))

    py = geo.exit_platform.min[1] - region.bounds.min[1]
    _, pzs, pxs = region.bounds.slices(geo.exit_platform)
    _, lzs, lxs = region.bounds.slices(lane)
    classes, passable = region.classes(), region.passable()
    platform_missing = classes[py, pzs, pxs] != BlockClass.SOLID
    platform_blocked = ~passable[py + 1, lzs, lxs]
    platform_gaps = [_world(geo.exit_platform, (0, iz, ix)) for iz, ix in np.argwhere(platform_missing)[:LEAKS_REPORTED]]
    platform_obstructed = [_world(lane, (1, iz, ix)) for iz, ix in np.argwhere(platform_blocked)[:LEAKS_REPORTED]]

    failing = [
        text for text, bad in (
            (f"{int(reach.sum())} leaks", leaks), ("entrance not open", not entrance_ok),
            (f"{len(undeclared)} undeclared opening cells", undeclared),
            ("composition off", any(d > tolerance for d in deviations.values())),
            (f"{int(missing.sum())} floor cells missing", gaps),
            (f"{int(platform_missing.sum())} exit platform cells missing", platform_gaps),
            (f"{int(platform_blocked.sum())} exit platform cells blocked above", platform_obstructed),
        ) if bad
    ]
    data = {
        "undeclared": undeclared[:LEAKS_REPORTED], "floor_missing": int(missing.sum()),
        "platform_missing": int(platform_missing.sum()), "platform_blocked": int(platform_blocked.sum()),
    }
    return MineResult(
        not failing, "; ".join(failing) or "mine valid",
        leaks + data["undeclared"] + gaps + platform_gaps + platform_obstructed, data,
        leaks=leaks, entrances_found=components, composition=_fractions(inner, names), deviations=deviations,
    )


def region_inside(inner: Bounds, outer: Bounds) -> Check:
    """``inner`` lies entirely within ``outer``; ``coords`` holds each corner of ``inner`` that does not."""
    outside = [tuple(int(v) for v in corner) for corner in (inner.min, inner.max) if not outer.contains(corner)]
    if outside:
        return Check(False, f"corner {outside[0]} is outside {outer.min}..{outer.max}", outside)
    return Check(True, "inside")
