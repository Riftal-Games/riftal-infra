"""``build_mine``: a box mine's shell, ore fill, entrance and exit platform as an ``EditList``."""

from __future__ import annotations

import numpy as np

from designer.blocks import AIR, format_name, parse_name
from designer.builders.base import Palette, facing_state, opposite
from designer.builders.mine_spec import SIDES, MineGeometry, MineSpec
from designer.edits import EditList, Fill, SetBlock
from designer.region import Bounds
from designer.world_index import Location, NamedRegion

# Bedrock yaw where south is 0 and it winds clockwise looking down, matching
# ``designer.builders.mine_spec.SIDES``.
_FACING_YAW = {"south": 0, "west": 90, "north": 180, "east": 270}


def _trim_ring(geo: MineGeometry, floor_y: int, block: str) -> list[Fill]:
    """A one-block ring of ``block`` on the wall layer touching the interior, at floor level."""
    x0, x1 = geo.interior.min[0] - 1, geo.interior.max[0] + 1
    z0, z1 = geo.interior.min[2] - 1, geo.interior.max[2] + 1
    return [
        Fill(Bounds((x0, floor_y, z0), (x1, floor_y, z0)), block), Fill(Bounds((x0, floor_y, z1), (x1, floor_y, z1)), block),
        Fill(Bounds((x0, floor_y, z0), (x0, floor_y, z1)), block), Fill(Bounds((x1, floor_y, z0), (x1, floor_y, z1)), block),
    ]


def _ore_ops(spec: MineSpec, interior: Bounds) -> list[SetBlock]:
    """One weighted, seeded draw per interior row: its ore layer's weights inside one, ``spec.ores`` outside every layer."""
    rng = np.random.default_rng(spec.seed)
    nx, _, nz = interior.size
    ops: list[SetBlock] = []
    for y in range(interior.min[1], interior.max[1] + 1):
        layer = next((l for l in spec.ore_layers if l.y_from <= y <= l.y_to), None)
        weights = layer.ores if layer is not None else spec.ores
        names = list(weights)
        p = np.fromiter(weights.values(), dtype=float)
        picks = rng.choice(len(names), size=(nz, nx), p=p / p.sum())
        ops.extend(
            SetBlock(interior.min[0] + dx, y, interior.min[2] + dz, names[picks[dz, dx]])
            for dz in range(nz) for dx in range(nx)
        )
    return ops


def _through_axis(side: str) -> tuple[int, int, int]:
    """``(through, lateral, sign)``: the axis the exit path travels along and the one across it."""
    axis, sign = SIDES[side]
    through, lateral = (0, 2) if axis == "x" else (2, 0)
    return through, lateral, sign


def build_mine(spec: MineSpec, palette: Palette) -> EditList:
    """The mine's shell, floor, ceiling, trim, ore (or a hollow interior), entrance and lit exit platform.

    ``solid`` fill leaves the interior a seeded block of ore for players to mine; ``hollow`` carves it to air.
    ``extras`` carries ``mine_reset`` (interior bounds, floor, ore weights, reset percent, for ``mines/`` to
    read), ``mine_spec`` (the spec re-serialised) and the index entries as ``locations``/``regions``.
    """
    geo = spec.geometry()
    through, lateral, sign = _through_axis(spec.entrance.side)
    face = geo.outer.max[through] if sign > 0 else geo.outer.min[through]
    centre = (geo.exit_platform.min[lateral] + geo.exit_platform.max[lateral] + 1) // 2
    edge = geo.exit_platform.min[lateral]

    def point(distance: int, lat: int = centre) -> tuple[int, int, int]:
        pos = [0, 0, 0]
        pos[through], pos[lateral], pos[1] = face + sign * distance, lat, spec.floor_y
        return pos[0], pos[1], pos[2]

    floor, ceiling = palette.block("floor"), palette.block("ceiling")
    light_base, light_states = parse_name(palette.block("light"))
    light = format_name(light_base, {**light_states, "hanging": False})
    sign_block = facing_state(palette.block("sign"), spec.entrance.side)

    floor_row = Bounds((geo.interior.min[0], spec.floor_y - 1, geo.interior.min[2]), (geo.interior.max[0], spec.floor_y - 1, geo.interior.max[2]))
    ceiling_row = Bounds((geo.interior.min[0], geo.interior.max[1] + 1, geo.interior.min[2]), (geo.interior.max[0], geo.interior.max[1] + 1, geo.interior.max[2]))

    ops: list[Fill | SetBlock] = [Fill(geo.outer, palette.block("wall")), Fill(floor_row, floor), Fill(ceiling_row, ceiling)]
    ops.extend(_trim_ring(geo, spec.floor_y, palette.block("wall_trim")))
    if spec.fill == "hollow":
        ops.append(Fill(geo.interior, AIR))
    else:
        ops.extend(_ore_ops(spec, geo.interior))
    ops.append(Fill(geo.entrance, AIR))
    ops.append(Fill(geo.exit_platform, floor))
    ops.extend(SetBlock(*point(d, edge), light) for d in range(spec.lights_every, spec.exit_path.length + 1, spec.lights_every))

    suffix = spec.name.rsplit("_", 1)[-1]
    into, out = _FACING_YAW[opposite(spec.entrance.side)], _FACING_YAW[spec.entrance.side]
    sell_pos, rankup_pos = point(spec.exit_path.length, centre - 1), point(spec.exit_path.length, centre + 1)
    ops.append(SetBlock(*sell_pos, sign_block))
    ops.append(SetBlock(*rankup_pos, sign_block))

    regions = [
        NamedRegion(spec.name, spec.world, geo.outer.min, geo.outer.max, spec.region_tags(), {"reset_percent": spec.reset_percent}),
        NamedRegion(f"{spec.name}_interior", spec.world, geo.interior.min, geo.interior.max, ["mine_interior"]),
        NamedRegion(f"{spec.name}_entrance", spec.world, geo.entrance.min, geo.entrance.max, ["mine", "walkway"]),
        NamedRegion(f"{spec.name}_exit_platform", spec.world, geo.exit_platform.min, geo.exit_platform.max, ["walkway"]),
    ]
    locations = [
        Location(f"{spec.name}_exit", spec.world, point(1), out, tags=["walkway"]),
        Location(f"{spec.name}_spawn", spec.world, point(spec.exit_path.length), into, tags=["spawn"]),
        Location(f"sell_npc_{suffix}", spec.world, sell_pos, out, tags=["npc", "sell"]),
        Location(f"rankup_npc_{suffix}", spec.world, rankup_pos, out, tags=["npc", "rankup"]),
    ]

    mine_reset = {
        "interior": geo.interior.to_json(), "floor_y": spec.floor_y, "ores": dict(spec.ores),
        "ore_layers": [{"y_from": l.y_from, "y_to": l.y_to, "ores": dict(l.ores)} for l in spec.ore_layers],
        "reset_percent": spec.reset_percent,
    }
    mine_spec_dict = {
        "name": spec.name, "world": spec.world, "origin": list(spec.origin), "size": list(spec.size),
        "wall_thickness": spec.wall_thickness, "floor_y": spec.floor_y,
        "entrance": {"side": spec.entrance.side, "width": spec.entrance.width, "height": spec.entrance.height, "offset": spec.entrance.offset},
        "exit_path": {"length": spec.exit_path.length, "width": spec.exit_path.width},
        "ores": dict(spec.ores), "ore_layers": mine_reset["ore_layers"], "fill": spec.fill,
        "seed": spec.seed, "lights_every": spec.lights_every, "reset_percent": spec.reset_percent,
        "safe_zone": spec.safe_zone,
    }
    extras = {
        "mine_reset": mine_reset, "mine_spec": mine_spec_dict,
        "locations": [l.to_json() for l in locations], "regions": [r.to_json() for r in regions],
    }
    return EditList(spec.world, ops, extras)
