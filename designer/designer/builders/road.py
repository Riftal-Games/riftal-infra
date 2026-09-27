"""``build_road``: a terrain-following road as an ``EditList``, paved, stepped and propped from a heightmap."""

from __future__ import annotations

from collections.abc import Sequence

import numpy as np

from designer.blocks import AIR
from designer.builders.base import DIRS, Palette, facing_state, perpendicular
from designer.builders.road_spec import Point, RoadSpec
from designer.edits import EditList, Fill, SetBlock
from designer.region import Bounds, Heightmap
from designer.world_index import NamedRegion

# Every fourth cell of an edged road gets a post, so a straight run reads as evenly spaced without crowding it.
EDGE_EVERY = 4

_NAMES = {step: name for name, step in DIRS.items()}


def _running_median(raw: Sequence[int], window: int) -> list[int]:
    """Each height replaced by the median of itself and its neighbours within ``window // 2`` either side."""
    half = window // 2
    return [int(round(float(np.median(raw[max(0, i - half):i + half + 1])))) for i in range(len(raw))]


def _slope_limit(values: Sequence[int]) -> list[int]:
    """``values`` walked in order, each clamped to within one block of the one before it."""
    limited = [values[0]]
    for v in values[1:]:
        prev = limited[-1]
        limited.append(max(prev - 1, min(prev + 1, v)))
    return limited


def road_profile(hm: Heightmap, centre: Sequence[Point], *, window: int = 3) -> list[int]:
    """The road's y per step of ``centre``: ground height smoothed by a running median, then slope-limited so no
    step to the next differs by more than one block, up or down."""
    raw = [hm.height(x, z) for x, z in centre]
    empty = [p for p, h in zip(centre, raw) if h < 0]
    if empty:
        raise ValueError(f"heightmap has no ground at {empty[0]}")
    return _slope_limit(_running_median(raw, window))


def _facings(centre: Sequence[Point]) -> list[str]:
    """Direction of travel at each point: the way out of the start, the way in everywhere after."""
    segs = [_NAMES[(q[0] - p[0], q[1] - p[1])] for p, q in zip(centre, centre[1:])]
    return [segs[0], *segs]


def build_road(spec: RoadSpec, palette: Palette, hm: Heightmap) -> EditList:
    """A road's surface, stairs where it climbs, air cleared above, an embankment below, posts along the edge.

    ``hm`` supplies the ground the road follows; see ``road_profile``. Every step paves the road role across
    ``width``, except a step that rises from the one before, which gets stairs facing the direction of travel
    instead. Air is cleared to ``clear_height`` above the surface, and where the surface sits above the ground
    ``hm`` reports, a wall-role fill props it up. With ``edge`` set, a road-edge post stands on each side every
    ``EDGE_EVERY`` steps. The built region is indexed tagged ``road`` and ``walkway``.
    """
    centre = spec.centre_line()
    profile = road_profile(hm, centre)
    ground = [hm.height(x, z) for x, z in centre]
    facings = _facings(centre)

    road, wall, edge_block = palette.block("road"), palette.block("wall"), palette.block("road_edge")
    stairs = palette.block("stairs")

    ops: list[Fill | SetBlock] = []
    for i, ((cx, cz), y, direction) in enumerate(zip(centre, profile, facings)):
        dx, dz = DIRS[perpendicular(direction)[1]]
        half = spec.width // 2
        lo, hi = (cx - dx * half, cz - dz * half), (cx + dx * (spec.width - 1 - half), cz + dz * (spec.width - 1 - half))

        rising = i > 0 and y > profile[i - 1]
        surface = facing_state(stairs, direction) if rising else road
        ops.append(Fill(Bounds((lo[0], y, lo[1]), (hi[0], y, hi[1])), surface))
        ops.append(Fill(Bounds((lo[0], y + 1, lo[1]), (hi[0], y + spec.clear_height, hi[1])), AIR))
        if ground[i] < y - 1:
            ops.append(Fill(Bounds((lo[0], ground[i] + 1, lo[1]), (hi[0], y - 1, hi[1])), wall))
        if spec.edge and i % EDGE_EVERY == 0:
            ops.append(SetBlock(lo[0], y + 1, lo[1], edge_block))
            ops.append(SetBlock(hi[0], y + 1, hi[1], edge_block))

    edits = EditList(spec.world, ops, {})
    box = edits.bounds
    region = NamedRegion(spec.name, spec.world, box.min, box.max, ["road", "walkway"])
    edits.extras["regions"] = [region.to_json()]
    return edits
