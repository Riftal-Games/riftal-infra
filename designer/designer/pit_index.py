"""The pit index and the 14 mine position sets (pit plan 6.1 and 15.1 item 8, spec 026).

``designer/pit/`` holds what an instance receives at boot: ``pit_index.json`` in world
coordinates, ``mine_sets/layer_01.bin`` to ``layer_14.bin``, and ``pit.sha256``, the
``sha256sum`` manifest ``images/plugins/deliver-pit-index.sh`` checks before it copies
anything. The sets are the ``packed_mud`` positions of the pinned structure, the same
bytes ``pit_matches_handoff`` check 02 and 03 hold the built level to.

    python -m designer.pit_index write    # regenerate designer/pit/ from designer/sources/
    python -m designer.pit_index check    # regenerate and compare with the committed files
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import Any

import numpy as np

from designer.mcstructure import open_structure, read_structure
from designer.pit_census import SOURCE_DIR, STRUCTURE, read_json
from designer.structure import StructureSpec

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "pit"
MAGIC = b"RPS1"
HEADER = struct.Struct("<4s7i")
PLACEHOLDER = "minecraft:packed_mud"
INDEX, MANIFEST = "pit_index.json", "pit.sha256"
POSITIONS = (
    "door_lower", "door_upper", "button_outside", "plate_inside", "outside_door", "interior_min", "interior_max",
    "bed_head", "bed_foot", "chest", "light",
)

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


def placeholder_positions(path: Path, spec: StructureSpec) -> np.ndarray:
    """World position of every ``packed_mud`` in the structure's first layer, one row each."""
    with open_structure(path) as stream:
        structure = read_structure(stream, _drain)
    mud = [i for i, state in enumerate(structure.palette) if state.name == PLACEHOLDER]
    _, sy, sz = structure.size
    found: list[np.ndarray] = [np.zeros((0, 3), dtype=np.int64)]

    def collect(layer: int, chunks: Any) -> None:
        for start, chunk in chunks:
            if layer == 0:
                i = start + np.flatnonzero(np.isin(chunk, mud))
                found.append(np.stack([i // (sy * sz), i // sz % sy, i % sz], axis=1))

    with open_structure(path) as stream:
        read_structure(stream, collect)
    return np.concatenate(found) + np.array(spec.world_min())


def layer_box(level: dict[str, Any], origin: Vec) -> tuple[Vec, Vec]:
    radius, (low, high) = level["bed_r"][1], level["bed_y"]
    return (origin[0] - radius, origin[1] + low, origin[2] - radius), (2 * radius + 1, high - low + 1, 2 * radius + 1)


def split_layers(points: np.ndarray, levels: list[dict[str, Any]], origin: Vec) -> dict[int, bytes]:
    """One set file per layer; every position falls in exactly one bed box and each box holds ``bed_blocks``."""
    files: dict[int, bytes] = {}
    claimed = np.zeros(len(points), dtype=bool)
    for level in levels:
        low, size = layer_box(level, origin)
        inside = ((points >= np.array(low)) & (points < np.array(low) + np.array(size))).all(axis=1)
        if int(inside.sum()) != level["bed_blocks"]:
            raise PitIndexError(f"layer {level['layer']}: {int(inside.sum())} placeholders, routes.json says {level['bed_blocks']}")
        files[level["layer"]], claimed = encode_set(low, size, points[inside]), claimed | inside
    if not claimed.all():
        raise PitIndexError(f"{int((~claimed).sum())} placeholders lie in no layer's bed box")
    return files


def _w(pos: list[int], origin: Vec) -> list[int]:
    return [pos[0] + origin[0], pos[1] + origin[1], pos[2] + origin[2]]


def _box(low: list[int], high: list[int], origin: Vec) -> dict[str, list[int]]:
    return {"min": _w(low, origin), "max": _w(high, origin)}


def index_document(
    source: Path, layout: dict[str, Any], world_index: dict[str, Any], origin: Vec, sets: dict[int, bytes]
) -> dict[str, Any]:
    routes, handoff, markers = (read_json(source / n) for n in ("routes.json", "cells.json", "markers.json"))
    levels = []
    for level in routes["levels"]:
        data = sets[level["layer"]]
        levels.append({
            "layer": level["layer"], "terrace_y": level["terrace_surface_y"] + origin[1], "stand_y": level["stand_y"] + origin[1],
            "wall_radius": level["wall_radius"], "walkway_r": level["walkway_r"], "bed_r": level["bed_r"],
            "bed_y": [y + origin[1] for y in level["bed_y"]], "set": {
                "file": set_name(level["layer"]), "count": HEADER.unpack_from(data)[7], "sha256": hashlib.sha256(data).hexdigest(),
            },
        })
    cells = [{**{k: c[k] for k in ("id", "layer", "row", "number", "faces")}, **{k: _w(c[k], origin) for k in POSITIONS}} for c in handoff["cells"]]
    ladders = [{"layer": d["layer"], "x": d["x"] + origin[0], "z": d["z"] + origin[2], "y_from": d["y_from"] + origin[1], "y_to": d["y_to"] + origin[1], "facing": d["facing"]} for d in handoff["ladders"]]
    stairs = [{"stair": s["stair"], "layer": s["layer"], "top": _w(s["top_landing"], origin), "bottom": _w(s["bottom_landing"], origin)} for s in routes["stairs"]]
    bays = {f"stair_bay_{n}": _box(markers[f"stair_{k}"]["min"], markers[f"stair_{k}"]["max"], origin) for k, n in zip("SENW", ("south", "east", "north", "west"), strict=True)}
    bridges = [
        {"bridge": b["bridge"], "terrace": b["terrace"], "end_a": _w(b["end_a"], origin), "end_b": _w(b["end_b"], origin), "deck_y": b["deck_y"] + origin[1],
         "deck_width": b["deck_width"], **_box(markers[f"bridge_{b['bridge']}"]["min"], markers[f"bridge_{b['bridge']}"]["max"], origin)}
        for b in routes["bridges"]
    ]
    floor, radius = routes["pit_floor"], routes["pit_floor"]["arena_radius"]
    mine = routes["contested_mine"]
    spawn = next(p for p in world_index["locations"] if p["name"] == "lumber_spawn" and p["world"] == "lumber")["pos"]
    margin = layout["lumber_exit_margin"]
    doorways = {n: {"world": d["world"], **_box(d["min"], d["max"], origin)} for n, d in layout["doorways"].items()}
    doorways["lumber_exit"] = {
        "world": "lumber", "min": [spawn[0] - margin, spawn[1], spawn[2] - margin], "max": [spawn[0] + margin, spawn[1] + 2, spawn[2] + margin],
    }
    return {
        "format": 1,
        "origin": list(origin),
        "build_box": _box(routes["build_box_local"]["min"], routes["build_box_local"]["max"], origin),
        "counts": {"layers": len(levels), "cells": len(cells), "ladders": len(ladders), "stairs": len(stairs), "bridges": len(bridges)},
        "layers": levels, "cells": cells, "ladders": ladders, "stairs": stairs,
        "transit": {**bays, **{n: _box(b["min"], b["max"], origin) for n, b in layout["transit"].items()}},
        "gate": {n: _box(b["min"], b["max"], origin) for n, b in layout["gate"].items()},
        "bridges": bridges,
        "arena": {"centre": [origin[0], origin[2]], "radius": radius, "y_min": floor["surface_y"] + origin[1], "y_max": floor["surface_y"] + origin[1] + layout["arena_height"] - 1},
        "contested": _box(mine["min"], mine["max"], origin),
        "warps": {n: {"pos": _w(w["local"], origin), "yaw": w["yaw"]} for n, w in routes["warps"].items()},
        "doorways": doorways,
        "points": {n: _w(p, origin) for n, p in layout["points"].items()},
    }


def build_files(source: Path = SOURCE_DIR, root: Path = ROOT) -> dict[str, bytes]:
    spec = StructureSpec.from_dict(read_json(root / "specs" / "pit_structure.json"))
    routes = read_json(source / "routes.json")
    sets = split_layers(placeholder_positions(source / STRUCTURE, spec), routes["levels"], spec.origin)
    document = index_document(source, read_json(root / "specs" / "pit_index.json"), read_json(root / "world_index.json"), spec.origin, sets)
    files = {set_name(layer): data for layer, data in sets.items()}
    files[INDEX] = (json.dumps(document, separators=(",", ":")) + "\n").encode("utf-8")
    files[MANIFEST] = "".join(f"{hashlib.sha256(files[n]).hexdigest()}  {n}\n" for n in sorted(files)).encode("utf-8")
    return files


def verify(directory: Path, source: Path = SOURCE_DIR) -> list[str]:
    """Every way ``directory`` differs from its own manifest, the index and routes.json; empty when none."""
    problems: list[str] = []
    manifest = (directory / MANIFEST).read_text(encoding="utf-8") if (directory / MANIFEST).is_file() else ""
    named = dict(line.split("  ", 1)[::-1] for line in manifest.splitlines())
    levels = read_json(source / "routes.json")["levels"]
    for name in [INDEX, *(set_name(level["layer"]) for level in levels)]:
        path = directory / name
        got = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "missing"
        if named.get(name) != got:
            problems.append(f"{name}: sha256 {got}, {MANIFEST} names {named.get(name)}")
    if problems:
        return problems
    index = json.loads((directory / INDEX).read_text(encoding="utf-8"))
    for level, entry in zip(levels, index["layers"], strict=True):
        try:
            count = len(decode_set((directory / entry["set"]["file"]).read_bytes())[2])
        except PitIndexError as exc:
            problems.append(f"{entry['set']['file']}: {exc}")
            continue
        if hashlib.sha256((directory / entry["set"]["file"]).read_bytes()).hexdigest() != entry["set"]["sha256"]:
            problems.append(f"{entry['set']['file']}: sha256 differs from the one {INDEX} names")
        if not count == entry["set"]["count"] == level["bed_blocks"]:
            problems.append(f"layer {level['layer']}: set {count}, index {entry['set']['count']}, routes.json {level['bed_blocks']}")
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
