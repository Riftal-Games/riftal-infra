"""Standing, pathing and travel time over a ``Region``. Pure numpy, no server."""

from __future__ import annotations

import heapq
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from designer.blocks import BlockClass
from designer.region import Bounds, Region

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


def stand_mask(region: Region) -> np.ndarray:
    """Bool ``[y][z][x]``: a player can stand with feet in the cell. See ``Region.stand_mask``."""
    return region.stand_mask()


def _snap(mask: np.ndarray, bounds: Bounds, pos: Sequence[int], radius: int) -> tuple[int, int, int] | None:
    """Local ``(iy, iz, ix)`` of the nearest standable cell within Chebyshev ``radius`` of ``pos``."""
    ix, iy, iz = (int(p) - lo for p, lo in zip(pos, bounds.min, strict=True))
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
    iy, iz, ix = local
    return ix + box.min[0], iy + box.min[1], iz + box.min[2]


def path_exists(
    region: Region, a: Sequence[int], b: Sequence[int], *,
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
        return PathResult(False, "start not standable", [tuple(int(v) for v in a)])
    goal = _snap(mask, region.bounds, b, snap_radius)
    if goal is None:
        return PathResult(False, "goal not standable", [tuple(int(v) for v in b)])
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
    region: Region, a: Sequence[int], b: Sequence[int], *, speed: float = WALK_SPEED, **path_kwargs: Any
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
    if iy < 0:
        return False
    return bool((classes[max(iy - n + 1, 0):iy + 1, iz, ix] == BlockClass.SOLID).any())


def entity_clear(region: Region, pos: Sequence[int]) -> Check:
    """A 1x2 hitbox with its feet at ``pos`` is free and whatever it rests on is walkable.

    Feet and head must be passable. The support is the first block below the
    feet that is neither air nor passable, and it must be solid, because a
    player over liquid sinks and over danger burns. A column with no support
    inside the region obstructs nothing here; ``warp_safe`` is the check that
    demands a landing. ``coords`` names the offending cells.
    """
    iy, iz, ix = region.bounds.local(pos)
    x, y, z = (int(v) for v in pos)
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


def warp_safe(region: Region, pos: Sequence[int]) -> Check:
    """``entity_clear`` at ``pos``, plus a landing a warp can drop a player onto.

    In order: the hitbox check; a solid block within ``LANDING`` blocks below
    the feet, so a warp over a hole or a void column is refused; no liquid or
    danger in the 3x3 at feet or head level, because the first step off the
    warp goes in any direction; and no cell in the 3x3 at floor level that is
    a hole deeper than ``LANDING``, so that step cannot be a fall either.
    ``detail`` names the first rule that fails and ``coords`` the cells that
    break it. Cells outside the region are unknown: they never offend, and
    they never count as solid.
    """
    clear = entity_clear(region, pos)
    if not clear.ok:
        return clear
    iy, iz, ix = region.bounds.local(pos)
    x, y, z = (int(v) for v in pos)
    classes = region.classes()
    ny, nz, nx = classes.shape
    if not _solid_within(classes, iy - 1, iz, ix, LANDING):
        return Check(False, f"no solid within {LANDING} below", [(x, y - 1, z)])
    around = [(dz, dx) for dz, dx in RING if 0 <= iz + dz < nz and 0 <= ix + dx < nx]
    hazards = [
        (x + dx, y + dy, z + dz)
        for dy in (0, 1) if iy + dy < ny
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


def region_inside(inner: Bounds, outer: Bounds) -> Check:
    """``inner`` lies entirely within ``outer``; ``coords`` holds each corner of ``inner`` that does not."""
    outside = [tuple(int(v) for v in corner) for corner in (inner.min, inner.max) if not outer.contains(corner)]
    if outside:
        return Check(False, f"corner {outside[0]} is outside {outer.min}..{outer.max}", outside)
    return Check(True, "inside")
