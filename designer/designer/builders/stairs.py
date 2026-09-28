"""``build_stairs``: a straight ascending staircase as an ``EditList``, propped below and cleared to stand in above."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from designer.blocks import AIR
from designer.builders.base import DIRS, Palette, facing_state, perpendicular
from designer.coords import int_coords, whole_int
from designer.edits import EditList, Fill
from designer.region import Bounds

Triple = tuple[int, int, int]

# Cells a stair step needs clear above it to stand on: the step itself is the
# solid floor, so ``Region.stand_mask`` wants only its own cell and the one
# above passable, the same minimum ``road.py``'s rising tiles rely on.
HEADROOM = 2


@dataclass(frozen=True)
class StairsSpec:
    """A straight staircase: ``base`` is the last flat tread before the climb, one row per step of ``rise`` toward ``direction``."""

    world: str
    base: Triple
    direction: str
    rise: int
    width: int = 1

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> StairsSpec:
        missing = [k for k in ("world", "from", "direction", "rise") if k not in data]
        if missing:
            raise ValueError(f"stairs spec is missing {missing}")
        try:
            if len(data["from"]) != 3:
                raise ValueError("from must be three integers")
            spec = cls(
                str(data["world"]), int_coords(data["from"], "from must be three integers"), str(data["direction"]),
                whole_int(data["rise"], "rise must be an integer"), whole_int(data.get("width", 1), "width must be an integer"),
            )
        except (TypeError, KeyError, IndexError) as e:
            raise ValueError(f"stairs spec is malformed: {e!r}") from e
        spec.validate()
        return spec

    def validate(self) -> None:
        if self.direction not in DIRS:
            raise ValueError(f"direction must be one of {sorted(DIRS)}, got {self.direction!r}")
        if self.rise < 1:
            raise ValueError(f"rise must be at least 1, got {self.rise}")
        if self.width < 1:
            raise ValueError(f"width must be at least 1, got {self.width}")


def _row(x: int, z: int, perp: tuple[int, int], width: int, y: int) -> Bounds:
    """The ``width``-wide row at ``y`` centred on ``(x, z)`` across ``perp``, leaning to the upper middle like a road's."""
    half = width // 2
    dx, dz = perp
    lo = (x - dx * half, z - dz * half)
    hi = (x + dx * (width - 1 - half), z + dz * (width - 1 - half))
    return Bounds((min(lo[0], hi[0]), y, min(lo[1], hi[1])), (max(lo[0], hi[0]), y, max(lo[1], hi[1])))


def build_stairs(spec: StairsSpec, palette: Palette) -> EditList:
    """``spec.rise`` stairs rows climbing from ``spec.base``, propped solid down to it and cleared ``HEADROOM`` above.

    Row ``i`` sits ``i`` blocks above ``base`` and ``i`` blocks along ``direction``, a stairs block from the
    ``stairs`` role facing the ascent. The support fill closes any gap between a row and ``base``'s height so the
    climb never opens over a void, and the headroom fill keeps it passable whatever stood there before.
    """
    dx, dz = DIRS[spec.direction]
    perp = DIRS[perpendicular(spec.direction)[1]]
    stairs = facing_state(palette.block("stairs"), spec.direction)
    support = palette.block("wall")
    bx, by, bz = spec.base

    ops: list[Fill] = []
    for i in range(1, spec.rise + 1):
        y = by + i
        row = _row(bx + dx * i, bz + dz * i, perp, spec.width, y)
        ops.append(Fill(row, stairs))
        ops.append(Fill(Bounds((row.min[0], by, row.min[2]), (row.max[0], y - 1, row.max[2])), support))
        ops.append(Fill(Bounds((row.min[0], y + 1, row.min[2]), (row.max[0], y + HEADROOM, row.max[2])), AIR))
    return EditList(spec.world, ops, {})
