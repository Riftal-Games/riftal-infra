"""A sparse miniature of the pit: the hand-off's own sample positions, standing places, two cells and a few placeholders.

Positions are local to the pit's origin ``0 66 0``. The cells, the ladder and the first stair landing sit at the
coordinates INTEGRATION.md quotes, and the rest is laid out so each of the thirteen checks has something to count.
``SAMPLES`` holds only with ``SAMPLES`` below, since the hall sits on the walkway and not 260 blocks under it.
"""

from __future__ import annotations

import copy
import struct
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

import numpy as np

from designer.blocks import parse_name
from designer.pit_handoff import Cells, Handoff, expected_blocks
from designer.region import Bounds, Region
from designer.verify import Pos
from tests.test_structure import _compound, _ints, _list, _s, _tag, bed_entity

ORIGIN = (0, 66, 0)
LOW, HIGH = (-16, -118, -30), (80, 150, 125)
BOX = Bounds((LOW[0], LOW[1] + ORIGIN[1], LOW[2]), (HIGH[0], HIGH[1] + ORIGIN[1], HIGH[2]))

STONE = "minecraft:stone"
CLAY = "minecraft:hardened_clay"
MUD = "minecraft:packed_mud"
DOOR = "minecraft:iron_door[door_hinge_bit=false,minecraft:cardinal_direction=west,open_bit=false,upper_block_bit={}]"
BED = "minecraft:bed[direction=0,head_piece_bit={},occupied_bit=false]"
BUTTON = "minecraft:stone_button[button_pressed_bit=false,facing_direction=4]"
PLATE = "minecraft:stone_pressure_plate[redstone_signal=0]"
CHEST = "minecraft:chest[minecraft:cardinal_direction=west]"
LADDER = "minecraft:ladder[facing_direction=5]"
LANTERN, SOUL = "minecraft:lantern[hanging=true]", "minecraft:soul_lantern[hanging=true]"


def _cell(cell_id: str, layer: int, dz: int) -> dict[str, Any]:
    def at(x: int, y: int, z: int) -> list[int]:
        return [x, y, z + dz]

    return {
        "id": cell_id, "layer": layer, "door_lower": at(75, 7, -24), "door_upper": at(75, 8, -24), "button_outside": at(74, 9, -24),
        "plate_inside": at(76, 7, -24), "chest": at(80, 7, -26), "bed_head": at(80, 7, -22), "bed_foot": at(79, 7, -22),
        "light": at(76, 10, -25), "interior_min": at(76, 7, -26), "interior_max": at(80, 10, -22),
    }


CELLS = [_cell("L08-R2-010", 8, 0), _cell("L09-R1-001", 9, 10)]
TOWER = [-0.5, -0.5]
SAMPLES = {
    "south stairway layer 1 bottom landing": ((11, 142, 122), (11, 208, 122)),
    "contested_mine_top": ((0, -115, 0), (0, -49, 0)),
    "deck_1": ((0, 142, 34), (0, 208, 34)),
    "hall": ((0, 142, 23), (0, 208, 23)),
    "cell L08-R2-010 door_lower": ((75, 7, -24), (75, 73, -24)),
}


def _bridge(layer: int, x: int) -> dict[str, Any]:
    return {
        "name": f"bridge_{layer}", "layer": layer, "tower_end": [x, 142, 36], "terrace_end": [x, 142, 96],
        "landing": {"name": f"landing_{layer}", "box_min": [x - 2, 141, 96], "box_max": [x + 2, 144, 100]},
    }


ROUTES: dict[str, Any] = {
    "decks": [
        {"deck": 1, "centre": TOWER, "bed_r": [3, 5], "bed_y": [60, 64], "bed_blocks": 3},
        {"deck": 2, "centre": TOWER, "bed_r": [2, 4], "bed_y": [40, 44], "bed_blocks": 2},
    ],
    "pit_floor": {"layer14_ring": {"r": [26, 39], "y": [-118, -117], "blocks": 3}},
    "contested_mine": {"centre": TOWER, "radius": 16, "box_min": [-1, -117, -1], "box_max": [1, -116, 1], "blocks": 18},
    "stairs": [
        {"stair": "south", "layer": 1, "top_landing": [-11, 142, 122], "bottom_landing": [11, 142, 122]},
        {"stair": "south", "layer": 2, "top_landing": [11, 142, 116], "bottom_landing": [-11, 142, 116]},
    ],
    "warps": {
        "rim_south": {"local": [0, 142, 110]}, "pit_floor": {"local": [0, 142, 100]}, "contested_mine_top": {"local": [0, -115, 0]},
        "gate_outside": {"local": [0, 2, 98]}, "gate_hall": {"local": [0, 2, 90]}, "layer_8": {"local": [0, 2, 70]},
        "layer_1": {"local": [0, 142, 120]}, "layer_2": {"local": [2, 142, 120]}, "deck_1": {"local": [0, 142, 34]},
        "deck_2": {"local": [2, 142, 34]}, "hall": {"local": [0, 142, 23]},
    },
    "bridges": [_bridge(1, 0), _bridge(2, 2)],
}
LADDERS = [{"layer": 1, "x": -14, "z": 110, "y_from": 142, "y_to": 146, "facing": "east"}]
MUD_AT = [(4, 60, 0), (-4, 61, 1), (0, 62, 4), (3, 40, 0), (-3, 41, 0), (30, -118, 0), (28, -117, 10), (27, -117, -5)]
CENSUS = {"size": [HIGH[a] - LOW[a] + 1 for a in range(3)], "block_names": {"minecraft:iron_door": 4, "minecraft:chest": 2, "minecraft:bed": 4}}


def world(local: Sequence[int]) -> Pos:
    return local[0] + ORIGIN[0], local[1] + ORIGIN[1], local[2] + ORIGIN[2]


def layout() -> dict[Pos, str]:
    """Every block of the miniature by world position, air left out."""
    put = {world((x, 141, z)): STONE for x in range(-12, 13) for z in range(96, 125)}
    put |= {world((x, 1, z)): STONE for x in range(-8, 9) for z in range(60, 101)}
    put |= {world((x, 141, z)): STONE for x in range(-2, 3) for z in range(20, 96)}
    put |= {world((x, y, z)): CLAY for x in range(-1, 2) for y in (-117, -116) for z in range(-1, 2)}
    for cell in CELLS:
        lantern = LANTERN if cell["layer"] <= 8 else SOUL
        for key, name in (
            ("door_lower", DOOR.format("false")), ("door_upper", DOOR.format("true")), ("button_outside", BUTTON), ("plate_inside", PLATE),
            ("chest", CHEST), ("bed_head", BED.format("true")), ("bed_foot", BED.format("false")), ("light", lantern),
        ):
            put[world(cell[key])] = name
    ladder = LADDERS[0]
    put |= {world((ladder["x"], y, ladder["z"])): LADDER for y in range(ladder["y_from"], ladder["y_to"] + 1)}
    return put | {world(at): MUD for at in MUD_AT}


def bed_colours() -> dict[Pos, int]:
    return {world(c[k]): 7 for c in CELLS for k in ("bed_head", "bed_foot")}


def cut(placed: dict[Pos, str], colours: dict[Pos, int]) -> Cells:
    """``placed`` as the 16 cube documents ``convert`` writes, keyed by corner."""
    docs: dict[Pos, dict[str, Any]] = {}
    for pos, name in placed.items():
        at = (pos[0] - pos[0] % 16, pos[1] - pos[1] % 16, pos[2] - pos[2] % 16)
        doc = docs.setdefault(at, {"palette": ["minecraft:air"], "blocks": [0] * 4096})
        if name not in doc["palette"]:
            doc["palette"].append(name)
        doc["blocks"][((pos[1] - at[1]) * 16 + pos[2] - at[2]) * 16 + pos[0] - at[0]] = doc["palette"].index(name)
    for pos, colour in colours.items():
        at = (pos[0] - pos[0] % 16, pos[1] - pos[1] % 16, pos[2] - pos[2] % 16)
        docs[at].setdefault("block_entities", []).append({"pos": [pos[a] - at[a] for a in range(3)], "color": colour})
    return docs


def handoff() -> Handoff:
    return Handoff(ORIGIN, BOX, copy.deepcopy(CELLS), copy.deepcopy(LADDERS), copy.deepcopy(ROUTES), copy.deepcopy(CENSUS))


@dataclass
class Pit:
    ref: Handoff
    docs: Cells
    region: Region


def build(placed: dict[Pos, str] | None = None) -> Pit:
    """``placed``, the whole miniature by default, as the server would read it back: exactly what the cell documents say."""
    placed = layout() if placed is None else placed
    docs = cut(placed, bed_colours())
    ids = {"minecraft:air": 0}
    blocks = expected_blocks(docs, BOX, ids)
    palette = [name for name, _ in sorted(ids.items(), key=lambda kv: kv[1])]
    return Pit(handoff(), docs, Region("zt", BOX, blocks, palette))


def _state(value: str) -> tuple[int, bytes]:
    if value in ("true", "false"):
        return 1, bytes([value == "true"])
    if value.lstrip("-").isdigit():
        return 3, struct.pack("<i", int(value))
    return 8, _s(value)


def structure_file(placed: dict[Pos, str], colours: dict[Pos, int]) -> bytes:
    """``placed`` as a ``.mcstructure`` over ``BOX``, states and bed colours kept."""
    size = tuple(CENSUS["size"])
    names: list[str] = []
    grid = np.full(size, -1, dtype="<i4")
    for pos, name in placed.items():
        if name not in names:
            names.append(name)
        grid[pos[0] - BOX.min[0], pos[1] - BOX.min[1], pos[2] - BOX.min[2]] = names.index(name)
    entries = []
    for key in names:
        base, states = parse_name(key)
        compound = _compound(*(_tag(kind, k, payload) for k, v in states.items() for kind, payload in [_state(v)]))
        entries.append(_compound(_tag(8, "name", _s(base)), _tag(10, "states", compound), _tag(3, "version", struct.pack("<i", 1))))
    sy, sz = size[1], size[2]
    data = _compound(*(
        _tag(10, str(((pos[0] - BOX.min[0]) * sy + pos[1] - BOX.min[1]) * sz + pos[2] - BOX.min[2]), _compound(_tag(10, "block_entity_data", bed_entity(colour))))
        for pos, colour in colours.items()
    ))
    layers = [bytes([3]) + struct.pack("<i", grid.size) + layer.tobytes() for layer in (grid.ravel(), np.full(grid.size, -1, dtype="<i4"))]
    structure = _compound(
        _tag(9, "block_indices", _list(9, layers)), _tag(9, "entities", _list(10, [])),
        _tag(10, "palette", _compound(_tag(10, "default", _compound(_tag(9, "block_palette", _list(10, entries)), _tag(10, "block_position_data", data))))),
    )
    return _tag(10, "", _compound(_tag(9, "size", _ints(list(size))), _tag(10, "structure", structure)))
