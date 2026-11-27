"""Pins and block-state census of the rift_prison hand-off (riftal-infra#1504).

``designer/sources/rift_prison/`` holds the hand-off byte for byte, ``pins.json``
with the sha256 of each file, and ``census.json``: every block state and
block-entity type with its count, and the pinned core image's verdict on each
(``resolution``, written by ``designer/sources/resolve.sh``).

    python -m designer.pit_census check    # the pins, and the census rebuilt from the gzip
    python -m designer.pit_census write    # rebuild census.json, keeping its resolution
    <core verdict> | python -m designer.pit_census resolution check|write [--census FILE]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np

from designer.mcstructure import open_structure, read_structure

SOURCE_DIR = Path(__file__).resolve().parent.parent / "sources" / "rift_prison"
CORE_PIN = Path(__file__).resolve().parents[2] / "images" / "core-image.sha"
STRUCTURE = "rift_prison_bedrock.mcstructure.gz"


def structure_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open_structure(path) as stream:
        while block := stream.read(1 << 22):
            digest.update(block)
    return digest.hexdigest()


def build_census(path: Path) -> dict[str, Any]:
    """Stream ``path`` once and count every state, block entity and entity."""
    hists: dict[int, np.ndarray] = {}
    void: dict[int, int] = {}

    def count(layer: int, chunks: Any) -> None:
        hist, void[layer] = np.zeros(0, dtype=np.int64), 0
        for _, chunk in chunks:
            used = chunk[chunk >= 0]
            void[layer] += len(chunk) - len(used)
            part = np.bincount(used)
            hist = np.pad(hist, (0, max(len(part) - len(hist), 0)))
            hist[: len(part)] += part
        hists[layer] = hist

    with open_structure(path) as stream:
        structure = read_structure(stream, count)
    if set(hists) != {0, 1} or any(len(h) > len(structure.palette) for h in hists.values()):
        raise ValueError(f"layers {sorted(hists)} do not match a palette of {len(structure.palette)}")
    for layer, hist in hists.items():
        if void[layer] + int(hist.sum()) != structure.cells:
            raise ValueError(f"layer {layer} holds {void[layer] + int(hist.sum())} cells, the size says {structure.cells}")

    rows: dict[str, dict[str, Any]] = {}
    for i, state in enumerate(structure.palette):
        row = rows.setdefault(
            state.key,
            {"key": state.key, "name": state.name, "states": state.states, "version": state.version, "count": 0, "count_layer_1": 0},
        )
        row["count"] += int(hists[0][i]) if i < len(hists[0]) else 0
        row["count_layer_1"] += int(hists[1][i]) if i < len(hists[1]) else 0
    names: Counter[str] = Counter()
    for row in rows.values():
        names[row["name"]] += row["count"]
    tiles = [str(v.get("id")) for v in structure.block_entities.values()]
    holding = [str(v.get("id")) for v in structure.block_entities.values() if v.get("Items")]
    return {
        "source_sha256": structure_sha256(path),
        "size": list(structure.size),
        "cells": structure.cells,
        "cells_without_state": {"layer_0": void[0], "layer_1": void[1]},
        "states": sorted(rows.values(), key=lambda r: r["key"]),
        "block_names": dict(sorted(names.items())),
        "block_entities": dict(sorted(Counter(tiles).items())),
        "block_entities_holding_items": dict(sorted(Counter(holding).items())),
        "entities": dict(sorted(Counter(str(e.get("identifier")) for e in structure.entities).items())),
    }


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: Any) -> None:
    path.write_bytes((json.dumps(data, indent=1, sort_keys=True) + "\n").encode("utf-8"))


def check(source_dir: Path = SOURCE_DIR, core_pin: str | None = None) -> list[str]:
    """Every way the committed sources differ from what they pin; empty when none.

    ``core_pin`` is the core image sha the census verdict must be for. It is the
    caller's to supply: the designer container mounts this directory alone.
    """
    pins = read_json(source_dir / "pins.json")
    problems = []
    for name, want in sorted(pins["files"].items()):
        path = source_dir / name
        got = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "missing"
        if got != want:
            problems.append(f"{name}: sha256 {got}, pinned {want}")
    if not (source_dir / STRUCTURE).is_file():
        return problems
    if (got := structure_sha256(source_dir / STRUCTURE)) != pins["structure_sha256"]:
        return [*problems, f"{STRUCTURE} unpacks to sha256 {got}, pinned {pins['structure_sha256']}"]
    committed, rebuilt = read_json(source_dir / "census.json"), build_census(source_dir / STRUCTURE)
    problems += [f"census.json {key} differs from the structure it pins" for key in sorted(rebuilt) if committed.get(key) != rebuilt[key]]
    got_core = (committed.get("resolution") or {}).get("core_image")
    if core_pin is not None and got_core != core_pin:
        problems.append(f"census.json resolution is for core image {got_core}, pin is {core_pin}")
    return problems


def compare_resolution(committed: dict[str, Any], reported: dict[str, Any]) -> list[str]:
    return [
        f"resolution {key}: committed {committed.get(key)!r}, core says {reported.get(key)!r}"
        for key in sorted(set(committed) | set(reported))
        if committed.get(key) != reported.get(key)
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="designer.pit_census")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    sub.add_parser("write")
    res = sub.add_parser("resolution")
    res.add_argument("mode", choices=("check", "write"))
    res.add_argument("--census", type=Path, default=SOURCE_DIR / "census.json")
    args = parser.parse_args(argv)

    problems: list[str] = []
    if args.cmd == "check":
        problems = check(core_pin=CORE_PIN.read_text(encoding="utf-8").strip())
    elif args.cmd == "write":
        path = SOURCE_DIR / "census.json"
        census = build_census(SOURCE_DIR / STRUCTURE)
        census["resolution"] = read_json(path).get("resolution", {}) if path.exists() else {}
        write_json(path, census)
    else:
        census, reported = read_json(args.census), json.load(sys.stdin)
        if args.mode == "write":
            write_json(args.census, {**census, "resolution": reported})
        else:
            problems = compare_resolution(census.get("resolution", {}), reported)
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
