"""``build_room``: a walled box with one door, as an ``EditList``. Shell then hollow, like ``build_mine``."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from designer.blocks import AIR, format_name, parse_name
from designer.builders.base import Palette
from designer.builders.mine_spec import SIDES
from designer.coords import int_coords, whole_int
from designer.edits import EditList, Fill, SetBlock
from designer.region import Bounds
from designer.world_index import Location, NamedRegion

Triple = tuple[int, int, int]


@dataclass(frozen=True)
class Door:
    side: str
    width: int
    height: int
    offset: int = 0


@dataclass(frozen=True)
class RoomGeometry:
    """``door`` is the one opening through the wall, read by both ``build_room`` and its tests."""

    outer: Bounds
    interior: Bounds
    door: Bounds


def _through_axis(side: str) -> tuple[int, int, int]:
    """``(through, lateral, sign)``: the axis a door on ``side`` cuts through, and the one across it."""
    axis, sign = SIDES[side]
    through, lateral = (0, 2) if axis == "x" else (2, 0)
    return through, lateral, sign


@dataclass(frozen=True)
class RoomSpec:
    """A walled box ``size`` at ``origin``, ``wall_thickness`` thick, one ``door``, lights on a
    ``lights_every`` grid across the ceiling."""

    name: str
    world: str
    origin: Triple
    size: Triple
    wall_thickness: int
    door: Door
    lights_every: int = 4

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> RoomSpec:
        missing = [k for k in ("name", "world", "origin", "size", "door") if k not in data]
        if missing:
            raise ValueError(f"room spec is missing {missing}")
        try:
            if any(len(data[k]) != 3 for k in ("origin", "size")):
                raise ValueError("origin and size must be three integers")
            origin, size = (int_coords(data[k], "origin and size must be three integers") for k in ("origin", "size"))
            door = data["door"]
            spec = cls(
                str(data["name"]), str(data["world"]), origin, size,
                whole_int(data.get("wall_thickness", 1), "wall_thickness must be an integer"),
                Door(
                    str(door["side"]), whole_int(door["width"], "door width must be an integer"),
                    whole_int(door["height"], "door height must be an integer"),
                    whole_int(door.get("offset", 0), "door offset must be an integer"),
                ),
                whole_int(data.get("lights_every", 4), "lights_every must be an integer"),
            )
        except (TypeError, KeyError, IndexError) as e:
            raise ValueError(f"room spec is malformed: {e!r}") from e
        spec.validate()
        return spec

    def validate(self) -> None:
        if self.door.side not in SIDES:
            raise ValueError(f"door side must be one of {sorted(SIDES)}, got {self.door.side!r}")
        w = self.wall_thickness
        if w < 1 or any(s <= 2 * w for s in self.size):
            raise ValueError(f"size {self.size} does not hold an interior inside walls of {w}")
        if min(self.door.width, self.door.height, self.lights_every) < 1:
            raise ValueError("door width, height and lights_every must be at least 1")
        geo, (_, lateral, _) = self.geometry(), _through_axis(self.door.side)
        if geo.door.min[lateral] < geo.interior.min[lateral] or geo.door.max[lateral] > geo.interior.max[lateral] or geo.door.max[1] > geo.interior.max[1]:
            raise ValueError(f"door {geo.door.min}..{geo.door.max} does not fit the wall beside the interior")

    def geometry(self) -> RoomGeometry:
        """``interior``: the shell hollowed by ``wall_thickness``. ``door``: centred on it, shifted by ``offset``."""
        outer = Bounds.from_size(self.origin, self.size)
        w = self.wall_thickness
        interior = Bounds((outer.min[0] + w, outer.min[1] + w, outer.min[2] + w), (outer.max[0] - w, outer.max[1] - w, outer.max[2] - w))
        through, lateral, sign = _through_axis(self.door.side)
        face = outer.max[through] if sign > 0 else outer.min[through]
        centre, half = (interior.min[lateral] + interior.max[lateral] + 1) // 2 + self.door.offset, self.door.width // 2
        lo, hi = [0, 0, 0], [0, 0, 0]
        lo[through], hi[through] = sorted((face, face - sign * (w - 1)))
        lo[lateral], hi[lateral] = centre - half, centre - half + self.door.width - 1
        lo[1], hi[1] = interior.min[1], interior.min[1] + self.door.height - 1
        return RoomGeometry(outer, interior, Bounds(tuple(lo), tuple(hi)))


def build_room(spec: RoomSpec, palette: Palette) -> EditList:
    """Shell filled solid, hollowed to ``geo.interior``, one doorway carved through, lights set into the ceiling
    every ``spec.lights_every`` on both axes. Location ``<name>_door`` sits one step outside the doorway, so a
    warp there faces in rather than stands in the frame."""
    geo = spec.geometry()
    wall = palette.block("wall")
    base, states = parse_name(palette.block("light"))
    light = format_name(base, {**states, "hanging": False})
    ops: list[Fill | SetBlock] = [Fill(geo.outer, wall), Fill(geo.interior, AIR), Fill(geo.door, AIR)]
    ceiling_y = geo.interior.max[1]
    ops.extend(
        SetBlock(x, ceiling_y, z, light)
        for x in range(geo.interior.min[0], geo.interior.max[0] + 1, spec.lights_every)
        for z in range(geo.interior.min[2], geo.interior.max[2] + 1, spec.lights_every)
    )
    through, lateral, sign = _through_axis(spec.door.side)
    face = geo.outer.max[through] + 1 if sign > 0 else geo.outer.min[through] - 1
    mid = (geo.door.min[lateral] + geo.door.max[lateral]) // 2
    door_pos = [face if a == through else mid if a == lateral else geo.door.min[1] for a in range(3)]
    region = NamedRegion(spec.name, spec.world, geo.outer.min, geo.outer.max, ["room"])
    location = Location(f"{spec.name}_door", spec.world, tuple(door_pos), tags=["door"])
    return EditList(spec.world, ops, {"regions": [region.to_json()], "locations": [location.to_json()]})
