"""``build_platform``: a flat, floored rectangle as an ``EditList``, cleared above and optionally railed."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from designer.blocks import AIR
from designer.builders.base import Palette, facing_state
from designer.coords import int_coord, int_coords
from designer.edits import EditList, Fill
from designer.region import Bounds, Bounds2D
from designer.world_index import NamedRegion

# Air kept clear above the floor: enough for a player to stand and look
# around, one more than ``stairs.HEADROOM`` because a platform is a place to
# stop, not a corridor to duck through.
CLEARANCE = 3


@dataclass(frozen=True)
class PlatformSpec:
    """A flat floor at ``y`` over ``footprint``, with an optional slab railing around its edge."""

    name: str
    world: str
    footprint: Bounds2D
    y: int
    railing: bool = False

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> PlatformSpec:
        missing = [k for k in ("name", "world", "min", "max", "y") if k not in data]
        if missing:
            raise ValueError(f"platform spec is missing {missing}")
        try:
            footprint = Bounds2D(*(int_coords(data[k], "min and max must be integers") for k in ("min", "max")))
            spec = cls(str(data["name"]), str(data["world"]), footprint, int_coord(data["y"], "y must be an integer"), bool(data.get("railing", False)))
        except (TypeError, KeyError, IndexError) as e:
            raise ValueError(f"platform spec is malformed: {e!r}") from e
        return spec


def _ring(x0: int, x1: int, z0: int, z1: int, y: int, block: str) -> list[Fill]:
    """A one-block ring of ``block`` at ``y`` around the rectangle's edge, one ``Fill`` per side."""
    return [
        Fill(Bounds((x0, y, z0), (x1, y, z0)), block), Fill(Bounds((x0, y, z1), (x1, y, z1)), block),
        Fill(Bounds((x0, y, z0), (x0, y, z1)), block), Fill(Bounds((x1, y, z0), (x1, y, z1)), block),
    ]


def build_platform(spec: PlatformSpec, palette: Palette) -> EditList:
    """A solid floor at ``spec.y``, air cleared ``CLEARANCE`` above it, and a bottom-half slab ring at the edge when ``spec.railing``.

    The floor is indexed as a ``NamedRegion`` tagged ``walkway``.
    """
    (x0, z0), (x1, z1) = spec.footprint.min, spec.footprint.max
    floor = Bounds((x0, spec.y, z0), (x1, spec.y, z1))
    air = Bounds((x0, spec.y + 1, z0), (x1, spec.y + CLEARANCE, z1))
    ops: list[Fill] = [Fill(floor, palette.block("floor")), Fill(air, AIR)]
    if spec.railing:
        rail = facing_state(palette.block("slab"), half="bottom")
        ops.extend(_ring(x0, x1, z0, z1, spec.y + 1, rail))

    region = NamedRegion(spec.name, spec.world, (x0, spec.y, z0), (x1, spec.y, z1), ["walkway"])
    return EditList(spec.world, ops, {"regions": [region.to_json()]})
