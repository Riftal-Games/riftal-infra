"""``build_hall``: a mine's spawn hall, entrance gate and sell and rank-up stalls, as an ``EditList``.

Everything is laid out in the mine's own frame: ``u`` across the walking lane (0 on its centre, the sell NPC at -1 and the
rank-up NPC at +1), ``d`` outward from the shell's outer face (the exit platform is ``d`` 1 to its length), ``y`` as is.
So one spec serves a mine on any side, and the hall never has to know which way it faces.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from designer.blocks import AIR
from designer.builders.base import Palette, facing_state
from designer.builders.mine_spec import SIDES, MineSpec
from designer.coords import whole_int
from designer.edits import EditList, Fill, SetBlock
from designer.region import Bounds

# The mine builder carves the platform's walking cells this high, so the hall carves only above them.
PLATFORM_HEADROOM = 2
MIN_HEIGHT = 4
# The sell and rank-up colours are the same in every tier, so a player learns them once, and neither is an ore material:
# panel, then the trim and floor tile.
SELL = ("minecraft:yellow_concrete", "minecraft:yellow_wool")
RANKUP = ("minecraft:blue_concrete", "minecraft:blue_wool")
LIGHT = "minecraft:lantern[hanging=true]"


@dataclass(frozen=True)
class HallSpec:
    """The ``mine`` the hall serves, exactly as its own spec reads, the hall's ``half_width`` either side of the lane and its carved ``height``.

    ``gap`` is how many cells either side of the lane the back wall leaves open, for stairs wider than one.
    """

    mine: MineSpec
    half_width: int = 4
    height: int = 4
    gap: int = 0

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> HallSpec:
        if "mine" not in data:
            raise ValueError("hall spec is missing ['mine']")
        try:
            spec = cls(
                MineSpec.from_dict(data["mine"]), whole_int(data.get("half_width", 4), "half_width must be an integer"),
                whole_int(data.get("height", MIN_HEIGHT), "height must be an integer"), whole_int(data.get("gap", 0), "gap must be an integer"),
            )
        except (TypeError, KeyError) as e:
            raise ValueError(f"hall spec is malformed: {e!r}") from e
        spec.validate()
        return spec

    def validate(self) -> None:
        if self.height < MIN_HEIGHT:
            raise ValueError(f"height must be at least {MIN_HEIGHT}, got {self.height}")
        if self.mine.exit_path.length < 2:
            raise ValueError(f"exit_path length must be at least 2 to hold a hall, got {self.mine.exit_path.length}")
        low, high = _Frame(self.mine).platform
        if self.half_width < 2 or self.half_width <= max(high, -low):
            raise ValueError(f"half_width {self.half_width} must clear the exit platform's {low}..{high} and be at least 2 for the stalls")
        if not 0 <= self.gap <= self.half_width - 2:
            raise ValueError(f"gap must be 0..{self.half_width - 2} to leave a stall either side of it, got {self.gap}")


class _Frame:
    """The mine's ``(u, d, y)`` frame: where its lane, outer face and exit platform sit in the zone."""

    def __init__(self, mine: MineSpec) -> None:
        geo = mine.geometry()
        axis, self.sign = SIDES[mine.entrance.side]
        self.through, self.lateral = (0, 2) if axis == "x" else (2, 0)
        self.face = geo.outer.max[self.through] if self.sign > 0 else geo.outer.min[self.through]
        platform = geo.exit_platform
        # The same centre build_mine puts its walking line and signs on.
        self.centre = (platform.min[self.lateral] + platform.max[self.lateral] + 1) // 2
        self.platform = (platform.min[self.lateral] - self.centre, platform.max[self.lateral] - self.centre)
        self.entrance_u = (geo.entrance.min[self.lateral] - self.centre, geo.entrance.max[self.lateral] - self.centre)
        self.entrance_d = tuple(self.sign * (geo.entrance.min[self.through] + k - self.face) for k in (0, geo.entrance.max[self.through] - geo.entrance.min[self.through]))

    def box(self, u: tuple[int, int], d: tuple[int, int], y: tuple[int, int]) -> Bounds:
        lo, hi = [0, 0, 0], [0, 0, 0]
        lo[self.through], hi[self.through] = (self.face + self.sign * k for k in d)
        lo[self.lateral], hi[self.lateral] = (self.centre + k for k in u)
        lo[1], hi[1] = y
        return Bounds(tuple(lo), tuple(hi))

    def cell(self, u: int, d: int, y: int) -> tuple[int, int, int]:
        return self.box((u, u), (d, d), (y, y)).min


def build_hall(spec: HallSpec, palette: Palette) -> EditList:
    """Carve beside and above the exit platform, then dress the hall, its two stalls and the gate in the shell's outer face.

    The platform's walking cells, the NPC cells, the entrance opening and the mine interior are never written. The
    boxes dug out of what is there go in ``extras["carve"]``, for ``build_level`` to refuse when any holds water or a cave.
    """
    mine, hw, height, gap = spec.mine, spec.half_width, spec.height, spec.gap
    frame, floor_y, length = _Frame(mine), mine.floor_y, mine.exit_path.length
    low, high = frame.platform
    top = floor_y + height
    wall, ceiling, pilaster = (palette.block(r) for r in ("hall_wall", "hall_ceiling", "pilaster"))
    cornice = facing_state(palette.block("cornice"), half="bottom")

    carve = [
        frame.box((-hw, low - 1), (1, length), (floor_y, top - 1)),
        frame.box((high + 1, hw), (1, length), (floor_y, top - 1)),
        frame.box((low, high), (1, length), (floor_y + PLATFORM_HEADROOM, top - 1)),
    ]
    ops: list[Fill | SetBlock] = [Fill(box, AIR) for box in carve]

    ops.append(Fill(frame.box((-hw, hw), (1, length), (floor_y - 1, floor_y - 1)), palette.block("hall_floor_a")))
    ops.append(Fill(frame.box((low, high), (1, length), (floor_y - 1, floor_y - 1)), wall))
    checker = palette.block("hall_floor_b")
    ops.extend(
        SetBlock(*frame.cell(u, d, floor_y - 1), checker)
        for d in range(1, length + 1) for u in range(-hw, hw + 1) if (u + d) % 2 == 0 and not low <= u <= high
    )
    ops.extend(SetBlock(*frame.cell(side, length, floor_y - 1), colour[1]) for side, colour in ((-1, SELL), (1, RANKUP)))
    ops.append(Fill(frame.box((-hw, hw), (1, length), (top, top)), ceiling))

    for side in (-1, 1):
        ops.append(Fill(frame.box((side * (hw + 1),) * 2, (1, length + 1), (floor_y - 1, top)), wall))
    # The stairs down to the pit start behind the NPCs, so the gap stays open there up to the ceiling.
    ops.extend(Fill(frame.box(u, (length + 1,) * 2, (floor_y, top)), wall) for u in ((-hw, -gap - 1), (gap + 1, hw)))
    ops.append(Fill(frame.box((-gap, gap), (length + 1,) * 2, (top, top)), wall))
    for (panel, trim), side in ((SELL, -1), (RANKUP, 1)):
        u = (side * (gap + 1), side * (hw - 1))
        ops.append(Fill(frame.box(u, (length + 1,) * 2, (floor_y, floor_y + 2)), panel))
        ops.append(Fill(frame.box(u, (length + 1,) * 2, (floor_y + 3, floor_y + 3)), trim))

    for d in range(2, length + 1, 2):
        ops.extend(Fill(frame.box((u, u), (d, d), (floor_y, top - 1)), pilaster) for u in (-hw, hw))
    ops.extend(SetBlock(*frame.cell(u, d, top - 1), LIGHT) for d in sorted({2, length - 1}) for u in (-(hw - 1), hw - 1))

    jamb, lintel, keystone = (palette.block(r) for r in ("gate_jamb", "gate_lintel", "keystone"))
    left, right = frame.entrance_u
    gate_d, rim = frame.entrance_d, (frame.entrance_d[1],) * 2
    arch = floor_y + mine.entrance.height
    ops.extend(Fill(frame.box(u, gate_d, (floor_y, arch - 1)), jamb) for u in ((left - 2, left - 1), (right + 1, right + 2)))
    ops.append(Fill(frame.box((left - 2, right + 2), gate_d, (arch, arch)), lintel))
    ops.extend(Fill(frame.box((u, u), rim, (floor_y, arch + 1)), wall) for u in (left - 3, right + 3))
    ops.append(Fill(frame.box((left - 2, right + 2), rim, (arch + 1, arch + 1)), wall))
    ops.append(SetBlock(*frame.cell((left + right) // 2, rim[0], arch + 1), keystone))
    ops.append(Fill(frame.box((left - 1, right + 1), rim, (arch + 2, arch + 2)), cornice))
    return EditList(mine.world, ops, {"carve": [box.to_json() for box in carve]})
