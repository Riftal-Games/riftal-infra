"""The pit index and the 15 mine position sets (pit plan 6.1 and 15.1 item 8, spec 026).

``designer/pit/`` holds what an instance receives at boot: ``pit_index.json`` in world
coordinates, ``mine_sets/layer_01.bin`` to ``layer_14.bin`` and ``contested.bin``, and
``pit.sha256``, the ``sha256sum`` manifest ``images/plugins/deliver-pit-index.sh`` checks before
it copies anything. Layers 1 to 13 are the ``packed_mud`` of each deck's bed, layer 14 the floor
ring, and ``contested.bin`` the ``terracotta`` of the contested cylinder, all of the pinned
structure: the same bytes ``pit_matches_handoff`` checks 02 to 04 hold the built level to.

    python -m designer.pit_index write    # regenerate designer/pit/ from designer/sources/
    python -m designer.pit_index check    # regenerate and compare with the committed files
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from pathlib import Path
from typing import Any, NamedTuple

import numpy as np

from designer.mcstructure import open_structure, read_structure
from designer.pit_census import SOURCE_DIR, STRUCTURE, read_json
from designer.structure import StructureSpec

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "pit"
MAGIC = b"RPS1"
HEADER = struct.Struct("<4s7i")
PLACEHOLDER = "minecraft:packed_mud"
# Bedrock's id for the plain terracotta routes.json calls contested_placeholder.
CONTESTED_PLACEHOLDER = "minecraft:hardened_clay"
INDEX, MANIFEST, CONTESTED = "pit_index.json", "pit.sha256", "mine_sets/contested.bin"
POSITIONS = (
    "door_lower", "door_upper", "button_outside", "plate_inside", "outside_door", "interior_min", "interior_max",
    "bed_head", "bed_foot", "chest", "light",
)
BANDS = {"south": ("z", 1), "north": ("z", -1), "east": ("x", 1), "west": ("x", -1)}
HALF_BAND = 16

Vec = tuple[int, int, int]


class PitIndexError(ValueError):
    """A set or the index is not what the hand-off says."""


def set_name(layer: int) -> str:
    return f"mine_sets/layer_{layer:02d}.bin"


def encode_set(origin: Vec, size: Vec, points: np.ndarray) -> bytes:
    sx, sy, sz = size
    rel = points - np.array(origin)
    if (rel < 0).any() or (rel >= np.array(size)).any():
        raise PitIndexError(f"a position lies outside the box {origin} + {size}")
    bits = np.zeros(sx * sy * sz, dtype=np.uint8)
    bits[(rel[:, 1] * sz + rel[:, 2]) * sx + rel[:, 0]] = 1
    return HEADER.pack(MAGIC, *origin, *size, int(bits.sum())) + np.packbits(bits, bitorder="little").tobytes()


def decode_set(data: bytes) -> tuple[Vec, Vec, np.ndarray]:
    """Origin, size and the world positions of the set bits; refuses any file the header does not describe."""
    if len(data) < HEADER.size or data[:4] != MAGIC:
        raise PitIndexError("wrong magic or header")
    _, ox, oy, oz, sx, sy, sz, count = HEADER.unpack_from(data)
    cells = sx * sy * sz
    if min(sx, sy, sz) < 1 or len(data) != HEADER.size + (cells + 7) // 8:
        raise PitIndexError("wrong length for the header's size")
    bits = np.unpackbits(np.frombuffer(data, np.uint8, offset=HEADER.size), bitorder="little")
    if bits[cells:].any() or int(bits.sum()) != count:
        raise PitIndexError(f"popcount {int(bits.sum())}, header says {count}")
    i = np.flatnonzero(bits[:cells])
    return (ox, oy, oz), (sx, sy, sz), np.stack([i % sx + ox, i // (sx * sz) + oy, i // sx % sz + oz], axis=1)


def _drain(_layer: int, chunks: Any) -> None:
    for _ in chunks:
        pass


def placeholder_positions(
    path: Path, spec: StructureSpec, names: tuple[str, ...] = (PLACEHOLDER, CONTESTED_PLACEHOLDER)
) -> dict[str, np.ndarray]:
    """World position of every block of each name in the structure's first layer, one row each."""
    with open_structure(path) as stream:
        structure = read_structure(stream, _drain)
    palette = {name: [i for i, state in enumerate(structure.palette) if state.name == name] for name in names}
    _, sy, sz = structure.size
    found: dict[str, list[np.ndarray]] = {name: [np.zeros((0, 3), dtype=np.int64)] for name in names}

    def collect(layer: int, chunks: Any) -> None:
        for start, chunk in chunks:
            if layer == 0:
                for name, ids in palette.items():
                    i = start + np.flatnonzero(np.isin(chunk, ids))
                    found[name].append(np.stack([i // (sy * sz), i // sz % sy, i % sz], axis=1))

    with open_structure(path) as stream:
        read_structure(stream, collect)
    return {name: np.concatenate(rows) + np.array(spec.world_min()) for name, rows in found.items()}


class Mine(NamedTuple):
    """One position set: its file, the block it holds, its box in local coordinates and the shape inside the box.

    ``tower`` is the half-open range of the distance from ``centre`` and ``pit_max`` the exclusive bound on the
    distance from the pit axis.
    """

    label: str
    file: str
    block: str
    low: Vec
    size: Vec
    count: int
    tower: tuple[float, float]
    pit_max: float
    centre: tuple[float, float]


def mines(routes: dict[str, Any]) -> list[Mine]:
    """The 13 deck beds, the floor ring and the contested cylinder, in the order of their files."""
    out = []
    for deck in routes["decks"]:
        (inner, outer), (low, high) = deck["bed_r"], deck["bed_y"]
        out.append(Mine(
            f"layer {deck['deck']}", set_name(deck["deck"]), PLACEHOLDER, (-outer, low, -outer), (2 * outer, high - low + 1, 2 * outer),
            deck["bed_blocks"], (inner, outer), math.inf, tuple(deck["centre"]),
        ))
    ring, tower = routes["pit_floor"]["layer14_ring"], routes["decks"][0]["centre"]
    (inner, outer), (low, high) = ring["r"], ring["y"]
    out.append(Mine(
        "layer 14", set_name(14), PLACEHOLDER, (1 - outer, low, 1 - outer), (2 * outer - 1, high - low + 1, 2 * outer - 1),
        ring["blocks"], (inner, math.inf), outer, tuple(tower),
    ))
    cylinder = routes["contested_mine"]
    size = tuple(h - m + 1 for m, h in zip(cylinder["box_min"], cylinder["box_max"], strict=True))
    out.append(Mine(
        "contested", CONTESTED, CONTESTED_PLACEHOLDER, tuple(cylinder["box_min"]), size, cylinder["blocks"],
        (0, cylinder["radius"]), math.inf, tuple(cylinder["centre"]),
    ))
    return out


def in_shape(mine: Mine, points: np.ndarray, origin: Vec) -> np.ndarray:
    """Which world ``points`` lie in the mine's box and shape, by squared distances so no edge depends on rounding."""
    local = points - np.array(origin)
    low, size = np.array(mine.low), np.array(mine.size)
    boxed = ((local >= low) & (local < low + size)).all(axis=1)
    tower = (local[:, 0] - mine.centre[0]) ** 2 + (local[:, 2] - mine.centre[1]) ** 2
    pit = local[:, 0].astype(float) ** 2 + local[:, 2] ** 2
    return boxed & (tower >= mine.tower[0] ** 2) & (tower < mine.tower[1] ** 2) & (pit < mine.pit_max**2)


def split_mines(found: dict[str, np.ndarray], routes: dict[str, Any], origin: Vec) -> dict[str, bytes]:
    """One set file per mine; each holds ``routes.json``'s count and every placeholder lies in exactly one."""
    files: dict[str, bytes] = {}
    claimed = {block: np.zeros(len(points), dtype=bool) for block, points in found.items()}
    for mine in mines(routes):
        inside = in_shape(mine, found[mine.block], origin)
        if int(inside.sum()) != mine.count:
            raise PitIndexError(f"{mine.label}: {int(inside.sum())} placeholders, routes.json says {mine.count}")
        low = (mine.low[0] + origin[0], mine.low[1] + origin[1], mine.low[2] + origin[2])
        files[mine.file] = encode_set(low, mine.size, found[mine.block][inside])
        claimed[mine.block] = claimed[mine.block] | inside
    stray = sum(int((~c).sum()) for c in claimed.values())
    if stray:
        raise PitIndexError(f"{stray} placeholders lie in no mine's shape")
    return files


def _w(pos: list[int], origin: Vec) -> list[int]:
    return [pos[0] + origin[0], pos[1] + origin[1], pos[2] + origin[2]]


def _box(low: list[int], high: list[int], origin: Vec) -> dict[str, list[int]]:
    return {"min": _w(low, origin), "max": _w(high, origin)}


def _set(files: dict[str, bytes], name: str) -> dict[str, Any]:
    return {"file": name, "count": HEADER.unpack_from(files[name])[7], "sha256": hashlib.sha256(files[name]).hexdigest()}


def _layers(routes: dict[str, Any], origin: Vec, files: dict[str, bytes]) -> list[dict[str, Any]]:
    layers = []
    for terrace, mine in zip(routes["terraces"], mines(routes)[:14], strict=True):
        k, y = terrace["layer"], [mine.low[1] + origin[1], mine.low[1] + mine.size[1] - 1 + origin[1]]
        shape = {"kind": "deck", "r_t": list(mine.tower)} if k < 14 else {"kind": "floor_ring", "r_t_min": mine.tower[0], "r_max": mine.pit_max}
        layers.append({
            "layer": k, "terrace_y": terrace["surface_y"] + origin[1], "stand_y": terrace["stand_y"] + origin[1], "wall_radius": terrace["wall_radius"],
            "walkway_r": terrace["walkway_r"], "mine": {**shape, "y": y, "set": _set(files, mine.file)},
        })
    return layers


def _decks(routes: dict[str, Any], origin: Vec) -> list[dict[str, Any]]:
    return [
        {
            "deck": d["deck"], "outer_radius": d["outer_radius"], "walkway_r_t": d["walkway_r"], "floor_y": [y + origin[1] for y in d["floor_y"]],
            "surface_y": d["surface_y"] + origin[1], "pillars": [[p["centre"][0] + origin[0], p["centre"][2] + origin[2]] for p in d["pillars"]],
            "bed_stair_tops": [_w(s["local"], origin) for s in d["bed_stairs_top_step"]], "bridges": d["bridges"],
        }
        for d in routes["decks"]
    ]


def _band(stairway: str, reach: int, y: tuple[int, int]) -> tuple[list[int], list[int]]:
    axis, sign = BANDS[stairway]
    along = (0, reach) if sign > 0 else (-reach, 0)
    if axis == "z":
        return [-HALF_BAND, y[0], along[0]], [HALF_BAND, y[1], along[1]]
    return [along[0], y[0], -HALF_BAND], [along[1], y[1], HALF_BAND]


def transit_regions(routes: dict[str, Any], layout: dict[str, Any], origin: Vec) -> list[dict[str, Any]]:
    """Each stairway's flights and balconies, the odd decks' landings, the gate hall and its arches.

    A flight or balcony is a band box plus ``r``, an inclusive range of the pit radius
    ``sqrt((x - ox)^2 + (z - oz)^2)`` over integer block x and z. The band stops at the rim's outer edge, so a flight
    never covers a bridge strip or the open pit in front of its bay. A region without ``r`` is the box alone.
    """
    terrace_y = {t["layer"]: t["surface_y"] for t in routes["terraces"]}
    terrace_y[0] = routes["rim"]["walkway_y"]
    walls = {t["layer"]: t["wall_radius"] for t in routes["terraces"]}
    reach = routes["rim"]["walkway_r"][1]
    out: list[dict[str, Any]] = []
    for stairway in BANDS:
        for k in range(1, 15):
            low, high = _band(stairway, reach, (terrace_y[k], terrace_y[k - 1] + 3))
            out.append({"name": f"flight_{stairway}_{k:02d}", "kind": "flight", **_box(low, high, origin), "r": [walls[k], reach]})
            if k < 14:
                low, high = _band(stairway, reach, (terrace_y[k], terrace_y[k] + 3))
                out.append({"name": f"balcony_{stairway}_{k:02d}", "kind": "balcony", **_box(low, high, origin), "r": [walls[k] - 7, walls[k]]})
    for bridge in routes["bridges"]:
        if bridge["layer"] % 2 and bridge["bearing"] in BANDS:
            landing = bridge["landing"]
            out.append({"name": landing["name"], "kind": "landing", **_box(landing["box_min"], landing["box_max"], origin)})
    return out + [{"name": n, "kind": "gate", **_box(b["min"], b["max"], origin)} for n, b in layout["transit"].items()]


def index_document(
    source: Path, layout: dict[str, Any], world_index: dict[str, Any], origin: Vec, files: dict[str, bytes]
) -> dict[str, Any]:
    routes, handoff = (read_json(source / n) for n in ("routes.json", "cells.json"))
    cells = [{**{k: c[k] for k in ("id", "layer", "row", "number", "faces")}, **{k: _w(c[k], origin) for k in POSITIONS}} for c in handoff["cells"]]
    ladders = [{"layer": d["layer"], "x": d["x"] + origin[0], "z": d["z"] + origin[2], "y_from": d["y_from"] + origin[1], "y_to": d["y_to"] + origin[1], "facing": d["facing"]} for d in handoff["ladders"]]
    stairs = [{"stair": s["stair"], "layer": s["layer"], "top": _w(s["top_landing"], origin), "bottom": _w(s["bottom_landing"], origin)} for s in routes["stairs"]]
    bridges = [
        {
            "name": b["name"], "deck": b["layer"], "bearing": b["bearing"], "tower_end": _w(b["tower_end"], origin), "terrace_end": _w(b["terrace_end"], origin),
            "deck_y": b["deck_y"] + origin[1], "width": b["width"], "walk_width": b["walk_width"],
            "landing": {"name": b["landing"]["name"], **_box(b["landing"]["box_min"], b["landing"]["box_max"], origin)},
        }
        for b in routes["bridges"]
    ]
    floor, cylinder = routes["pit_floor"], routes["contested_mine"]
    hall, ring, tower = floor["hall"], floor["layer14_ring"], routes["decks"][0]["centre"]
    spawn = next(p for p in world_index["locations"] if p["name"] == "lumber_spawn" and p["world"] == "lumber")["pos"]
    margin = layout["lumber_exit_margin"]
    doorways = {n: {"world": d["world"], **_box(d["min"], d["max"], origin)} for n, d in layout["doorways"].items()}
    doorways["lumber_exit"] = {
        "world": "lumber", "min": [spawn[0] - margin, spawn[1], spawn[2] - margin], "max": [spawn[0] + margin, spawn[1] + 2, spawn[2] + margin],
    }
    transit = transit_regions(routes, layout, origin)
    counts = {"layers": 14, "decks": len(routes["decks"]), "cells": len(cells), "ladders": len(ladders), "stairs": len(stairs), "bridges": len(bridges), "transit": len(transit)}
    return {
        "format": 2,
        "origin": list(origin),
        "centres": {"pit": [origin[0], origin[2]], "tower": [tower[0] + origin[0], tower[1] + origin[2]]},
        "build_box": _box(routes["build_box_local"]["min"], routes["build_box_local"]["max"], origin),
        "counts": counts,
        "layers": _layers(routes, origin, files), "decks": _decks(routes, origin), "cells": cells, "ladders": ladders, "stairs": stairs,
        "transit": transit,
        "gate": {n: _box(b["min"], b["max"], origin) for n, b in layout["gate"].items()},
        "bridges": bridges,
        "floor": {
            "surface_y": floor["surface_y"] + origin[1], "wall_walkway_r": floor["wall_walkway_r"],
            "ring": {"r_t_min": ring["r"][0], "r_max": ring["r"][1], "y": [y + origin[1] for y in ring["y"]], "blocks": ring["blocks"]},
            "causeways": [{"name": n, "width": c["width"], "from_r": c["from_r"], "to_r": c["to_r"], "y": c["y"] + origin[1]} for n, c in floor["causeways"].items()],
        },
        "hall": {"r_t_max": hall["radius"], "y": [cylinder["y"][0] + origin[1], hall["ceiling_y"] + origin[1] - 1]},
        "contested": {
            "centre": [cylinder["centre"][0] + origin[0], cylinder["centre"][1] + origin[2]], "radius": cylinder["radius"],
            "y": [y + origin[1] for y in cylinder["y"]], "set": _set(files, CONTESTED),
        },
        "warps": {n: {"pos": _w(w["local"], origin), "yaw": w["yaw"]} for n, w in routes["warps"].items()},
        "doorways": doorways,
        "points": {n: _w(p, origin) for n, p in layout["points"].items()},
    }


def build_files(source: Path = SOURCE_DIR, root: Path = ROOT) -> dict[str, bytes]:
    spec = StructureSpec.from_dict(read_json(root / "specs" / "pit_structure.json"))
    routes = read_json(source / "routes.json")
    files = split_mines(placeholder_positions(source / STRUCTURE, spec), routes, spec.origin)
    document = index_document(source, read_json(root / "specs" / "pit_index.json"), read_json(root / "world_index.json"), spec.origin, files)
    files[INDEX] = (json.dumps(document, separators=(",", ":")) + "\n").encode("utf-8")
    files[MANIFEST] = "".join(f"{hashlib.sha256(files[n]).hexdigest()}  {n}\n" for n in sorted(files)).encode("utf-8")
    return files


def verify(directory: Path, source: Path = SOURCE_DIR) -> list[str]:
    """Every way ``directory`` differs from its own manifest, the index and routes.json; empty when none."""
    problems: list[str] = []
    manifest = (directory / MANIFEST).read_text(encoding="utf-8") if (directory / MANIFEST).is_file() else ""
    named: dict[str, str] = {}
    for line in manifest.splitlines():
        digest, separator, name = line.partition("  ")
        if separator:
            named[name] = digest
        else:
            problems.append(f"{MANIFEST}: malformed line {line!r}")
    wanted = mines(read_json(source / "routes.json"))
    for name in [INDEX, *(mine.file for mine in wanted)]:
        path = directory / name
        got = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "missing"
        if named.get(name) != got:
            problems.append(f"{name}: sha256 {got}, {MANIFEST} names {named.get(name)}")
    if problems:
        return problems
    index = json.loads((directory / INDEX).read_text(encoding="utf-8"))
    entries = [*(layer["mine"]["set"] for layer in index["layers"]), index["contested"]["set"]]
    for mine, entry in zip(wanted, entries, strict=True):
        try:
            count = len(decode_set((directory / entry["file"]).read_bytes())[2])
        except PitIndexError as exc:
            problems.append(f"{entry['file']}: {exc}")
            continue
        if hashlib.sha256((directory / entry["file"]).read_bytes()).hexdigest() != entry["sha256"]:
            problems.append(f"{entry['file']}: sha256 differs from the one {INDEX} names")
        if not count == entry["count"] == mine.count:
            problems.append(f"{mine.label}: set {count}, index {entry['count']}, routes.json {mine.count}")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="designer.pit_index")
    parser.add_argument("mode", choices=("write", "check"))
    args = parser.parse_args(argv)
    files = build_files()
    problems: list[str] = []
    if args.mode == "write":
        for name, data in files.items():
            (OUT_DIR / name).parent.mkdir(parents=True, exist_ok=True)
            (OUT_DIR / name).write_bytes(data)
    else:
        problems = [f"{name} differs from the structure it is built from" for name, data in files.items() if not (OUT_DIR / name).is_file() or (OUT_DIR / name).read_bytes() != data]
    problems += verify(OUT_DIR)
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
