"""A mine's spec and the one geometry the builder and ``mine_valid`` both read."""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from designer.blocks import format_name, parse_name
from designer.coords import int_coord, int_coords, whole_int
from designer.region import Bounds

# Side name to the axis it faces along and the direction along it.
SIDES = {"north": ("z", -1), "south": ("z", 1), "west": ("x", -1), "east": ("x", 1)}
FILLS = ("solid", "hollow")

Triple = tuple[int, int, int]

# Every block PocketMine builds as a Crops subclass, which RiftalMines' MineRegistry refuses outside a one-layer interior.
CROPS = frozenset(f"minecraft:{n}" for n in ("wheat", "carrots", "potatoes", "beetroot", "melon_stem", "pumpkin_stem"))
FARMLAND = "minecraft:farmland"
WETNESS_STATE = "moisturized_amount"
FULL_WETNESS = 7

# A key must name a block id, so no key can spell the marker mine_valid gives a block outside its reset state.
BLOCK_ID = re.compile(r"[a-z0-9_.-]+:[a-z0-9_./-]+")


def _weights(data: Any, key: str) -> dict[str, float]:
    ores = {format_name(*parse_name(name)): float(w) for name, w in dict(data).items()}
    if not ores or min(ores.values()) <= 0:
        raise ValueError(f"{key} must name at least one block with a positive weight, got {data!r}")
    for name in ores:
        if not BLOCK_ID.fullmatch(parse_name(name)[0]):
            raise ValueError(f"{key} names {name!r}, which is not a block id")
    # A block in both keys' states would count under whichever came first, so the other could never be satisfied.
    parsed = [(name, *parse_name(name)) for name in ores]
    for i, (a, ab, astates) in enumerate(parsed):
        for b, bb, bstates in parsed[i + 1:]:
            if ab == bb and (astates.items() <= bstates.items() or bstates.items() <= astates.items()):
                raise ValueError(f"{key} names {a!r} and {b!r}, which one block can satisfy both of")
    # RiftalMines resets through StringToItemParser::parse, which strips only "minecraft:" and
    # whose aliases hold no ':', '[' or '=', so any other key throws at reset (#650).
    for name, base, states in parsed:
        if states or not base.startswith("minecraft:"):
            raise ValueError(f"{key} names {name!r}, which the mine reset cannot resolve: it takes a bare minecraft: id")
    return ores


def _flag(value: Any, key: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{key} must be true or false, got {value!r}")
    return value


@dataclass(frozen=True)
class Entrance:
    side: str
    width: int
    height: int
    offset: int = 0


@dataclass(frozen=True)
class ExitPath:
    length: int
    width: int


@dataclass(frozen=True)
class OreLayer:
    y_from: int
    y_to: int
    ores: dict[str, float]


@dataclass(frozen=True)
class MineGeometry:
    """``interior`` is the mined box; ``entrance`` the opening through the wall; ``exit_platform`` the floor outside it."""

    outer: Bounds
    interior: Bounds
    entrance: Bounds
    exit_platform: Bounds
    padding: Bounds


@dataclass(frozen=True)
class MineSpec:
    name: str
    world: str
    origin: Triple
    size: Triple
    wall_thickness: int
    floor_y: int
    entrance: Entrance
    exit_path: ExitPath
    ores: dict[str, float]
    ore_layers: tuple[OreLayer, ...] = ()
    fill: str = "solid"
    seed: int = 0
    lights_every: int = 4
    reset_percent: int = 60
    safe_zone: bool = True

    @property
    def has_crop(self) -> bool:
        """An ore, in ``ores`` or a layer, is a crop: its mine stands on farmland and refills one row."""
        names = [*self.ores, *(name for layer in self.ore_layers for name in layer.ores)]
        return any(parse_name(name)[0] in CROPS for name in names)

    def reset_interior(self) -> Bounds:
        """The box the mine reset refills: the interior, or only its bottom row for a crop mine, which has headroom above it."""
        interior = self.geometry().interior
        if not self.has_crop:
            return interior
        return Bounds(interior.min, (interior.max[0], interior.min[1], interior.max[2]))

    def reset_floor_y(self) -> int:
        """The ``floor_y`` of the ``mine_reset`` fragment. A crop is refilled one layer above it, on the farmland the build wrote there."""
        return self.floor_y - 1 if self.has_crop else self.floor_y

    def region_tags(self) -> list[str]:
        """Tags for the outer region. Design plan 6.1 makes a regular mine safe by default; 7.2 keeps the contested mine PvP."""
        return ["mine", "safe_zone"] if self.safe_zone else ["mine"]

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> MineSpec:
        missing = [k for k in ("name", "world", "origin", "size", "floor_y", "entrance", "exit_path", "ores") if k not in data]
        if missing:
            raise ValueError(f"mine spec is missing {missing}")
        try:
            if any(len(data[k]) != 3 for k in ("origin", "size")):
                raise ValueError("origin and size must be three integers")
            origin, size = (int_coords(data[k], "origin and size must be three integers") for k in ("origin", "size"))
            door, path = data["entrance"], data["exit_path"]
            spec = cls(
                str(data["name"]), str(data["world"]), origin, size,
                whole_int(data.get("wall_thickness", 2), "wall_thickness must be an integer"),
                int_coord(data["floor_y"], "floor_y must be an integer"),
                Entrance(
                    str(door["side"]), whole_int(door["width"], "entrance width must be an integer"),
                    whole_int(door["height"], "entrance height must be an integer"),
                    whole_int(door.get("offset", 0), "entrance offset must be an integer"),
                ),
                ExitPath(
                    whole_int(path["length"], "exit_path length must be an integer"),
                    whole_int(path["width"], "exit_path width must be an integer"),
                ),
                _weights(data["ores"], "ores"),
                tuple(
                    OreLayer(*int_coords((l["y_from"], l["y_to"]), "y_from and y_to must be integers"), _weights(l["ores"], "ore_layers"))
                    for l in data.get("ore_layers") or ()
                ),
                str(data.get("fill", "solid")), whole_int(data.get("seed", 0), "seed must be an integer"),
                whole_int(data.get("lights_every", 4), "lights_every must be an integer"),
                whole_int(data.get("reset_percent", 60), "reset_percent must be an integer"),
                _flag(data.get("safe_zone", True), "safe_zone"),
            )
        except (TypeError, KeyError) as e:
            raise ValueError(f"mine spec is malformed: {e!r}") from e
        spec.validate()
        return spec

    def validate(self) -> None:
        if self.entrance.side not in SIDES:
            raise ValueError(f"entrance side must be one of {sorted(SIDES)}, got {self.entrance.side!r}")
        if self.fill not in FILLS:
            raise ValueError(f"fill must be one of {FILLS}, got {self.fill!r}")
        if self.wall_thickness < 1 or any(s <= 2 * self.wall_thickness for s in self.size):
            raise ValueError(f"size {self.size} does not hold an interior inside walls of {self.wall_thickness}")
        if min(self.entrance.width, self.entrance.height, self.exit_path.length, self.lights_every) < 1:
            raise ValueError("entrance, exit_path and lights_every dimensions must be at least 1")
        # The walking line runs down the platform's centre with a sign on each side of it on the
        # last row and the lights on its low-coordinate edge; narrower than 3 puts the lights on the
        # walking line or a sign off the platform.
        if self.exit_path.width < 3:
            raise ValueError(f"exit_path width must be at least 3 to hold both signs beside the walking line, got {self.exit_path.width}")
        if not 1 <= self.reset_percent <= 100:
            raise ValueError(f"reset_percent must be 1..100, got {self.reset_percent}")
        if self.has_crop and self.ore_layers:
            raise ValueError("a crop mine refills one row from ores alone, so it takes no ore_layers")
        geo = self.geometry()
        if not geo.outer.min[1] < self.floor_y <= geo.interior.max[1]:
            raise ValueError(f"floor_y {self.floor_y} needs a floor above y {geo.outer.min[1]} and room below the top wall")
        lateral = 2 if SIDES[self.entrance.side][0] == "x" else 0
        if any(geo.entrance.min[a] < geo.interior.min[a] or geo.entrance.max[a] > geo.interior.max[a] for a in (lateral, 1)):
            raise ValueError(f"entrance {geo.entrance.min}..{geo.entrance.max} does not fit the wall beside the interior")
        for layer in self.ore_layers:
            if not geo.interior.min[1] <= layer.y_from <= layer.y_to <= geo.interior.max[1]:
                raise ValueError(f"ore layer {layer.y_from}..{layer.y_to} is outside the interior y {geo.interior.min[1]}..{geo.interior.max[1]}")
        spans = sorted((layer.y_from, layer.y_to) for layer in self.ore_layers)
        if any(a[1] >= b[0] for a, b in zip(spans, spans[1:])):
            raise ValueError(f"ore layers {spans} overlap")

    def geometry(self) -> MineGeometry:
        """Bounds of every part. The entrance is centred on the interior, an even width leaning to the upper middle, plus ``offset``."""
        outer = Bounds.from_size(self.origin, self.size)
        w = self.wall_thickness
        interior = Bounds((outer.min[0] + w, self.floor_y, outer.min[2] + w), (outer.max[0] - w, outer.max[1] - w, outer.max[2] - w))
        axis, sign = SIDES[self.entrance.side]
        through, lateral = (0, 2) if axis == "x" else (2, 0)
        face = outer.max[through] if sign > 0 else outer.min[through]
        centre = (interior.min[lateral] + interior.max[lateral] + 1) // 2 + self.entrance.offset

        def box(along: tuple[int, int], width: int, ys: tuple[int, int]) -> Bounds:
            lo, hi = [0, 0, 0], [0, 0, 0]
            lo[through], hi[through] = along
            lo[lateral], hi[lateral] = centre - width // 2, centre - width // 2 + width - 1
            lo[1], hi[1] = ys
            return Bounds(tuple(lo), tuple(hi))

        entrance = box((face - sign * (w - 1), face), self.entrance.width, (self.floor_y, self.floor_y + self.entrance.height - 1))
        platform = box((face + sign, face + sign * self.exit_path.length), self.exit_path.width, (self.floor_y - 1, self.floor_y - 1))
        return MineGeometry(outer, interior, entrance, platform, outer.expand(1))
