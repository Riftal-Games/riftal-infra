"""The rift_prison pins, the streaming structure reader and the committed census."""

from __future__ import annotations

import gzip
import hashlib
import json
from pathlib import Path

import pytest

from designer import mcstructure, pit_census
from designer.mcstructure import StructureError, open_structure, read_structure

SOURCES = pit_census.SOURCE_DIR
# tiny.mcstructure: 2x2x2, layer 0 is [0, 1, -1, 1, 0, 0, 2, -1] over the palette
# air, chest[dir=north,lit=true,n=4], stone; layer 1 is all -1; cell 1 is a Chest
# block entity holding one item.
TINY = (Path(__file__).parent / "fixtures" / "tiny.mcstructure").read_bytes()
LAYER0_AT = TINY.index(bytes.fromhex("00000000 01000000 ffffffff".replace(" ", "")))

# Listed on riftal-infra#1504 with a proposed substitute each.
UNRESOLVED = {
    "minecraft:dripstone_block",
    "minecraft:moss_block",
    "minecraft:scaffolding[stability=0,stability_check=true]",
}


@pytest.fixture
def small_chunks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mcstructure, "BULK_MIN", 4)
    monkeypatch.setattr(mcstructure, "CHUNK_CELLS", 3)


@pytest.fixture
def source(tmp_path: Path, small_chunks: None) -> Path:
    """A source directory holding the tiny structure and pins that match it."""
    (tmp_path / pit_census.STRUCTURE).write_bytes(gzip.compress(TINY, mtime=0))
    (tmp_path / "cells.json").write_text("{}")
    files = {n: hashlib.sha256((tmp_path / n).read_bytes()).hexdigest() for n in ("cells.json", pit_census.STRUCTURE)}
    census = pit_census.build_census(tmp_path / pit_census.STRUCTURE)
    census["resolution"] = {"core_image": "c0re"}
    pit_census.write_json(tmp_path / "pins.json", {"files": files, "structure_sha256": hashlib.sha256(TINY).hexdigest()})
    pit_census.write_json(tmp_path / "census.json", census)
    return tmp_path


def _open(tmp_path: Path, raw: bytes = TINY):
    path = tmp_path / "s.mcstructure"
    path.write_bytes(raw)
    return open_structure(path)


def test_reader_streams_each_layer_in_chunks(tmp_path: Path, small_chunks: None) -> None:
    seen: dict[int, list[tuple[int, list[int]]]] = {}
    with _open(tmp_path) as stream:
        structure = read_structure(stream, lambda layer, chunks: seen.update({layer: [(s, c.tolist()) for s, c in chunks]}))
    assert seen[0] == [(0, [0, 1, -1]), (3, [1, 0, 0]), (6, [2, -1])]
    assert seen[1][0] == (0, [-1, -1, -1])
    assert structure.size == (2, 2, 2) and structure.cells == 8
    assert structure.palette[1].key == "minecraft:chest[dir=north,lit=true,n=4]"
    assert structure.palette[1].states == {"dir": "north", "lit": True, "n": 4}
    assert structure.block_entities[1]["id"] == "Chest"


def test_reader_refuses_to_materialise_a_long_layer(tmp_path: Path, small_chunks: None) -> None:
    with _open(tmp_path) as stream, pytest.raises(StructureError, match="nothing to stream"):
        read_structure(stream)


def test_reader_refuses_a_truncated_file(tmp_path: Path, small_chunks: None) -> None:
    with _open(tmp_path, TINY[:-30]) as stream, pytest.raises(StructureError, match="truncated"):
        read_structure(stream, lambda layer, chunks: [*chunks])


def test_census_counts_states_and_block_entities(source: Path) -> None:
    census = pit_census.build_census(source / pit_census.STRUCTURE)
    assert {r["key"]: (r["count"], r["count_layer_1"]) for r in census["states"]} == {
        "minecraft:air": (3, 0),
        "minecraft:chest[dir=north,lit=true,n=4]": (2, 0),
        "minecraft:stone": (1, 0),
    }
    assert census["cells_without_state"] == {"layer_0": 2, "layer_1": 8}
    assert census["block_entities"] == census["block_entities_holding_items"] == {"Chest": 1}
    assert census["entities"] == {}


def test_check_passes_on_matching_sources(source: Path) -> None:
    assert pit_census.check(source, core_pin="c0re") == []


def test_check_names_a_changed_and_a_missing_pinned_file(source: Path) -> None:
    (source / "cells.json").write_text('{"cells": 1}')
    assert any(p.startswith("cells.json: sha256") for p in pit_census.check(source, core_pin="c0re"))
    (source / "cells.json").unlink()
    assert any("cells.json: sha256 missing" in p for p in pit_census.check(source, core_pin="c0re"))


def test_check_names_a_structure_that_unpacks_to_other_bytes(source: Path) -> None:
    other = TINY[:LAYER0_AT] + b"\x02" + TINY[LAYER0_AT + 1 :]
    (source / pit_census.STRUCTURE).write_bytes(gzip.compress(other, mtime=0))
    pins = json.loads((source / "pins.json").read_text())
    pins["files"][pit_census.STRUCTURE] = hashlib.sha256((source / pit_census.STRUCTURE).read_bytes()).hexdigest()
    pit_census.write_json(source / "pins.json", pins)
    assert any("unpacks to sha256" in p for p in pit_census.check(source, core_pin="c0re"))


def test_check_names_a_census_that_drifted_and_a_verdict_for_another_core(source: Path) -> None:
    census = json.loads((source / "census.json").read_text())
    census["states"][0]["count"] += 1
    pit_census.write_json(source / "census.json", census)
    problems = pit_census.check(source, core_pin="other")
    assert "census.json states differs from the structure it pins" in problems
    assert any("pin is other" in p for p in problems)


def test_compare_resolution_names_each_difference() -> None:
    committed = {"unresolved": [], "core_image": "a"}
    assert pit_census.compare_resolution(committed, dict(committed)) == []
    got = pit_census.compare_resolution(committed, {"unresolved": [{"key": "x"}], "core_image": "a"})
    assert len(got) == 1 and got[0].startswith("resolution unresolved")


def test_committed_sources_match_their_pins() -> None:
    assert pit_census.check() == []


def test_committed_census_holds_the_hand_off_headline() -> None:
    census = json.loads((SOURCES / "census.json").read_text())
    names = census["block_names"]
    assert names["minecraft:packed_mud"] == 97395
    assert names["minecraft:hardened_clay"] == 3200
    assert names["minecraft:iron_door"] >= 3738
    assert names["minecraft:chest"] >= 1869
    assert census["block_entities"]["Chest"] == names["minecraft:chest"]
    assert census["block_entities"]["Bed"] == names["minecraft:bed"]
    assert sum(names.values()) + census["cells_without_state"]["layer_0"] == census["cells"] == 46567062


def test_committed_resolution_names_exactly_the_listed_unresolved_states() -> None:
    resolution = json.loads((SOURCES / "census.json").read_text())["resolution"]
    assert {row["key"] for row in resolution["unresolved"]} == UNRESOLVED
    assert resolution["altered"] == resolution["block_entities_unknown"] == []
