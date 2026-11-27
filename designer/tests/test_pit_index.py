"""The pit index, the 14 mine position sets and their delivery before the server starts (riftal-infra#1507)."""

from __future__ import annotations

import gzip
import json
import shutil
import subprocess
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from designer import mcstructure, pit_index
from designer.pit_census import SOURCE_DIR, read_json
from designer.pit_index import MANIFEST, OUT_DIR, PitIndexError, decode_set, encode_set, set_name
from designer.structure import StructureSpec
from tests import test_structure
from tests.test_structure import structure_bytes

FIXTURE = Path(__file__).parent / "fixtures" / "set_4x2x3.bin"
SCRIPT = Path(__file__).resolve().parents[2] / "images" / "plugins" / "deliver-pit-index.sh"
BED_BLOCKS = [11757, 11004, 10249, 9634, 8720, 8186, 7269, 6419, 5888, 5217, 4115, 3724, 2953, 2260]
INDEX_PLUGINS = ("RiftalMines", "RiftalRanks", "RiftalCells")
SETS = tuple(set_name(layer) for layer in range(1, 15))
# Bits 0, 3, 10, 17 and 20 of a 4 x 2 x 3 box at (10, 60, -3), i = ((y - oy) * 3 + (z - oz)) * 4 + (x - ox), worked by hand.
FIXTURE_POINTS = [(10, 60, -3), (13, 60, -3), (12, 60, -1), (11, 61, -2), (10, 61, -1)]


def test_the_fixture_set_is_the_bytes_the_format_defines() -> None:
    raw = FIXTURE.read_bytes()
    assert raw == b"RPS1" + b"".join(v.to_bytes(4, "little", signed=True) for v in (10, 60, -3, 4, 2, 3, 5)) + bytes([0x09, 0x04, 0x12])
    assert encode_set((10, 60, -3), (4, 2, 3), np.array(FIXTURE_POINTS)) == raw
    origin, size, points = decode_set(raw)
    assert (origin, size) == ((10, 60, -3), (4, 2, 3))
    assert sorted(map(tuple, points.tolist())) == sorted(FIXTURE_POINTS)


@pytest.mark.parametrize(
    ("damage", "message"),
    [
        (lambda b: b"RPS2" + b[4:], "magic"),
        (lambda b: b[:-1], "length"),
        (lambda b: b + b"\x00", "length"),
        (lambda b: b[:-1] + b"\x13", "popcount"),
        (lambda b: b[:-1] + b"\xf2", "popcount"),
    ],
)
def test_a_set_the_header_does_not_describe_is_refused(damage: Any, message: str) -> None:
    with pytest.raises(PitIndexError, match=message):
        decode_set(damage(FIXTURE.read_bytes()))


def test_a_position_outside_the_box_is_refused() -> None:
    with pytest.raises(PitIndexError, match="outside the box"):
        encode_set((0, 0, 0), (2, 2, 2), np.array([(2, 0, 0)]))


@pytest.fixture
def mud(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mcstructure, "BULK_MIN", 4)
    monkeypatch.setattr(mcstructure, "CHUNK_CELLS", 5)
    monkeypatch.setattr(test_structure, "PALETTE", ["minecraft:air", "minecraft:stone", "minecraft:packed_mud"])


def test_the_scan_returns_each_placeholder_in_world_coordinates(mud: None, tmp_path: Path) -> None:
    placed = {(0, 0, 0): 2, (2, 1, 3): 2, (1, 0, 1): 1, (1, 1, 1): 0}
    path = tmp_path / "s.mcstructure.gz"
    path.write_bytes(gzip.compress(structure_bytes((3, 2, 4), placed, {}), mtime=0))
    spec = StructureSpec("pit", "s", "s", (0, 66, 0), (-1, -1, -2), {})
    found = pit_index.placeholder_positions(path, spec)
    assert sorted(map(tuple, found.tolist())) == [(-1, 65, -2), (1, 66, 1)]


def level(layer: int, blocks: int) -> dict[str, Any]:
    return {"layer": layer, "bed_r": [0, 1], "bed_y": [0, 1], "bed_blocks": blocks}


def test_a_layer_whose_count_is_not_bed_blocks_is_refused() -> None:
    points = np.array([(0, 66, 0), (1, 67, 1)])
    assert len(pit_index.split_layers(points, [level(1, 2)], (0, 66, 0))) == 1
    with pytest.raises(PitIndexError, match="layer 1: 2 placeholders, routes.json says 3"):
        pit_index.split_layers(points, [level(1, 3)], (0, 66, 0))


def test_a_placeholder_in_no_layers_bed_box_is_refused() -> None:
    with pytest.raises(PitIndexError, match="1 placeholders lie in no layer"):
        pit_index.split_layers(np.array([(0, 66, 0), (9, 66, 9)]), [level(1, 1)], (0, 66, 0))


def test_the_14_committed_counts_equal_routes_json_bed_blocks() -> None:
    routes = read_json(SOURCE_DIR / "routes.json")
    assert [lv["bed_blocks"] for lv in routes["levels"]] == BED_BLOCKS
    index = json.loads((OUT_DIR / "pit_index.json").read_text(encoding="utf-8"))
    assert [e["set"]["count"] for e in index["layers"]] == BED_BLOCKS
    for layer, wanted in enumerate(BED_BLOCKS, 1):
        assert len(decode_set((OUT_DIR / set_name(layer)).read_bytes())[2]) == wanted
    assert pit_index.verify(OUT_DIR) == []


def test_the_committed_files_are_what_the_pinned_structure_builds() -> None:
    built = pit_index.build_files()
    assert {n: (OUT_DIR / n).read_bytes() for n in built} == built


def test_the_index_holds_the_positions_integration_md_quotes() -> None:
    index = json.loads((OUT_DIR / "pit_index.json").read_text(encoding="utf-8"))
    south = next(s for s in index["stairs"] if s["stair"] == "south" and s["layer"] == 1)
    assert south["bottom"] == [11, 208, 122]
    assert next(c for c in index["cells"] if c["id"] == "L08-R2-010")["door_lower"] == [75, 73, -24]
    assert index["warps"]["contested_mine_top"]["pos"] == [0, -49, 0]
    assert index["counts"] == {"layers": 14, "cells": 1869, "ladders": 111, "stairs": 56, "bridges": 4}


def tampered(tmp_path: Path, name: str) -> Path:
    copy = tmp_path / "pit"
    shutil.copytree(OUT_DIR, copy)
    raw = bytearray((copy / name).read_bytes())
    raw[-1] ^= 0x01
    (copy / name).write_bytes(bytes(raw))
    return copy


@pytest.mark.parametrize("name", [set_name(3), "pit_index.json"])
def test_the_verifier_fails_a_tampered_file_by_name(tmp_path: Path, name: str) -> None:
    problems = pit_index.verify(tampered(tmp_path, name))
    assert len(problems) == 1
    assert problems[0].startswith(f"{name}: sha256")


needs_script = pytest.mark.skipif(not SCRIPT.is_file(), reason="images/plugins is not mounted, as in the container test run")


def deliver(tmp_path: Path, pit: Path, *command: str) -> tuple[subprocess.CompletedProcess[str], Path]:
    """Runs deliver-pit-index.sh with /etc/riftal and /data moved under a scratch root."""
    root = tmp_path / "root"
    (root / "etc").mkdir(parents=True)
    shutil.copytree(pit, root / "etc" / "pit")
    script = root / "deliver.sh"
    script.write_bytes(SCRIPT.read_bytes().replace(b"/etc/riftal", f"{root.as_posix()}/etc".encode()).replace(b"/data/plugin_data", f"{root.as_posix()}/data/plugin_data".encode()))
    done = subprocess.run([shutil.which("bash") or "bash", str(script), *command], capture_output=True, text=True, check=False)
    return done, root / "data" / "plugin_data"


@needs_script
def test_a_boot_delivers_the_index_to_three_folders_and_the_sets_to_mines_alone_then_starts(tmp_path: Path) -> None:
    done, data = deliver(tmp_path, OUT_DIR, "printf", "%s|", "started")
    assert (done.returncode, done.stdout) == (0, "started|")
    for plugin in INDEX_PLUGINS:
        assert (data / plugin / "pit_index.json").read_bytes() == (OUT_DIR / "pit_index.json").read_bytes()
    for name in SETS:
        assert (data / "RiftalMines" / name).read_bytes() == (OUT_DIR / name).read_bytes()
    assert sorted(p.name for p in data.iterdir()) == sorted(INDEX_PLUGINS)
    for plugin in ("RiftalRanks", "RiftalCells"):
        assert sorted(p.name for p in (data / plugin).iterdir()) == ["pit_index.json"]
    assert not (data / "RiftalCustody").exists()


@needs_script
@pytest.mark.parametrize("name", [set_name(3), set_name(14), "pit_index.json"])
def test_a_tampered_file_stops_the_boot_before_the_start_command_and_delivers_nothing(tmp_path: Path, name: str) -> None:
    done, data = deliver(tmp_path, tampered(tmp_path, name), "printf", "started")
    assert done.returncode != 0
    assert "started" not in done.stdout
    assert f"{name}: FAILED" in done.stderr
    assert not data.exists()


@needs_script
def test_a_missing_set_or_manifest_stops_the_boot(tmp_path: Path) -> None:
    short = tmp_path / "short"
    shutil.copytree(OUT_DIR, short)
    (short / set_name(9)).unlink()
    done, data = deliver(tmp_path, short, "printf", "started")
    assert done.returncode != 0 and "started" not in done.stdout
    assert "layer_09.bin" in done.stderr
    assert not data.exists()
    bare = tmp_path / "bare"
    bare.mkdir()
    done, _ = deliver(tmp_path / "second", bare, "printf", "started")
    assert done.returncode != 0 and f"{MANIFEST} is not mounted" in done.stderr


@needs_script
def test_a_manifest_that_omits_a_set_stops_the_boot(tmp_path: Path) -> None:
    omitted = tmp_path / "omitted"
    shutil.copytree(OUT_DIR, omitted)
    lines = (omitted / MANIFEST).read_text(encoding="utf-8").splitlines(keepends=True)
    (omitted / MANIFEST).write_text("".join(line for line in lines if "layer_05" not in line), encoding="utf-8", newline="\n")
    done, data = deliver(tmp_path, omitted, "printf", "started")
    assert done.returncode != 0 and "mine_sets/layer_05.bin is not named" in done.stderr
    assert not data.exists()


def test_a_malformed_manifest_line_is_a_problem_line_not_an_exception(tmp_path: Path) -> None:
    copy = tmp_path / "pit"
    shutil.copytree(OUT_DIR, copy)
    with (copy / MANIFEST).open("a", encoding="utf-8", newline="\n") as manifest:
        manifest.write("not a manifest line\n")
    assert pit_index.verify(copy) == [f"{MANIFEST}: malformed line 'not a manifest line'"]


def test_a_bridge_strip_carries_its_end_points_deck_y_and_width_only() -> None:
    index = json.loads((OUT_DIR / "pit_index.json").read_text(encoding="utf-8"))
    assert len(index["bridges"]) == 4
    for bridge in index["bridges"]:
        assert sorted(bridge) == ["bridge", "deck_width", "deck_y", "end_a", "end_b", "terrace"]
