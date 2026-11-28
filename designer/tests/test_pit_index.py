"""The pit index, the 15 mine position sets and their delivery before the server starts (riftal-infra#1507)."""

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
from designer.pit_index import CONTESTED, CONTESTED_PLACEHOLDER, MANIFEST, OUT_DIR, PLACEHOLDER, PitIndexError, decode_set, encode_set, set_name
from designer.structure import StructureSpec
from tests import test_structure
from tests.test_structure import structure_bytes

FIXTURE = Path(__file__).parent / "fixtures" / "set_4x2x3.bin"
SCRIPT = Path(__file__).resolve().parents[2] / "images" / "plugins" / "deliver-pit-index.sh"
BED_BLOCKS = [19140, 17916, 16668, 15492, 14388, 13356, 12324, 11292, 10404, 9348, 8508, 7740, 6900, 11718]
CONTESTED_BLOCKS = 5824
INDEX_PLUGINS = ("RiftalMines", "RiftalRanks", "RiftalCells")
SETS = (*(set_name(layer) for layer in range(1, 15)), CONTESTED)
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
    found = pit_index.placeholder_positions(path, spec, (PLACEHOLDER,))
    assert sorted(map(tuple, found[PLACEHOLDER].tolist())) == [(-1, 65, -2), (1, 66, 1)]


TOWER = [-0.5, -0.5]
ORIGIN = (0, 66, 0)
MINI = {
    "decks": [{"deck": 1, "centre": TOWER, "bed_r": [1, 3], "bed_y": [0, 1], "bed_blocks": 1}],
    "pit_floor": {"layer14_ring": {"r": [26, 39], "y": [-5, -4], "blocks": 1}},
    "contested_mine": {"centre": TOWER, "radius": 2, "box_min": [-2, -9, -2], "box_max": [1, -8, 1], "blocks": 1},
}
BED, RING, CYLINDER = (1, 66, 0), (30, 61, 0), (0, 57, 0)


def mini(mud: list[tuple[int, int, int]], **override: Any) -> dict[str, bytes]:
    found = {PLACEHOLDER: np.array(mud), CONTESTED_PLACEHOLDER: np.array([CYLINDER])}
    return pit_index.split_mines(found, {**MINI, **override}, ORIGIN)


def test_each_placeholder_goes_to_the_set_whose_shape_holds_it() -> None:
    files = mini([BED, RING])
    assert sorted(files) == [CONTESTED, set_name(1), set_name(14)]
    for name, want in ((set_name(1), BED), (set_name(14), RING), (CONTESTED, CYLINDER)):
        assert decode_set(files[name])[2].tolist() == [list(want)]


def test_a_mine_whose_count_is_not_routes_jsons_is_refused() -> None:
    deck = {**MINI["decks"][0], "bed_blocks": 2}
    with pytest.raises(PitIndexError, match="layer 1: 1 placeholders, routes.json says 2"):
        mini([BED, RING], decks=[deck])


def test_a_placeholder_in_no_mines_shape_is_refused() -> None:
    inside_the_spine = (0, 66, 0)
    with pytest.raises(PitIndexError, match="1 placeholders lie in no mine's shape"):
        mini([BED, RING, inside_the_spine])


def test_the_ring_stops_before_pit_radius_39() -> None:
    with pytest.raises(PitIndexError, match="1 placeholders lie in no mine's shape"):
        mini([BED, RING, (39, 61, 0)])


def test_the_ring_outer_edge_is_the_pit_radius_not_the_tower_radius() -> None:
    with pytest.raises(PitIndexError, match="1 placeholders lie in no mine's shape"):
        mini([BED, RING, (-39, 61, 0)])


def test_the_15_committed_counts_equal_routes_json() -> None:
    routes = read_json(SOURCE_DIR / "routes.json")
    assert [d["bed_blocks"] for d in routes["decks"]] + [routes["pit_floor"]["layer14_ring"]["blocks"]] == BED_BLOCKS
    assert routes["contested_mine"]["blocks"] == CONTESTED_BLOCKS
    assert sum(BED_BLOCKS) == routes["mines"]["total_packed_mud"] == 175194
    index = json.loads((OUT_DIR / "pit_index.json").read_text(encoding="utf-8"))
    assert [e["mine"]["set"]["count"] for e in index["layers"]] == BED_BLOCKS
    assert index["contested"]["set"]["count"] == CONTESTED_BLOCKS
    for layer, wanted in enumerate(BED_BLOCKS, 1):
        assert len(decode_set((OUT_DIR / set_name(layer)).read_bytes())[2]) == wanted
    assert len(decode_set((OUT_DIR / CONTESTED).read_bytes())[2]) == CONTESTED_BLOCKS
    assert pit_index.verify(OUT_DIR) == []


def test_the_committed_files_are_what_the_pinned_structure_builds() -> None:
    built = pit_index.build_files()
    assert {n: (OUT_DIR / n).read_bytes() for n in built} == built


def test_the_index_holds_the_positions_integration_md_quotes() -> None:
    index = json.loads((OUT_DIR / "pit_index.json").read_text(encoding="utf-8"))
    south = next(s for s in index["stairs"] if s["stair"] == "south" and s["layer"] == 1)
    assert south["bottom"] == [11, 208, 122]
    assert next(c for c in index["cells"] if c["id"] == "L08-R2-010")["door_lower"] == [75, 73, -24]
    warps = {name: warp["pos"] for name, warp in index["warps"].items()}
    assert (warps["contested_mine_top"], warps["deck_1"], warps["hall"]) == ([0, -55, 6], [0, 208, 34], [0, -52, 23])
    assert index["counts"] == {"layers": 14, "decks": 13, "cells": 1869, "ladders": 111, "stairs": 56, "bridges": 52, "transit": 139}


def tampered(tmp_path: Path, name: str) -> Path:
    copy = tmp_path / "pit"
    shutil.copytree(OUT_DIR, copy)
    raw = bytearray((copy / name).read_bytes())
    raw[-1] ^= 0x01
    (copy / name).write_bytes(bytes(raw))
    return copy


@pytest.mark.parametrize("name", [set_name(3), CONTESTED, "pit_index.json"])
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
def test_a_boot_delivers_the_index_and_all_15_sets_to_three_folders_then_starts(tmp_path: Path) -> None:
    done, data = deliver(tmp_path, OUT_DIR, "printf", "%s|", "started")
    assert (done.returncode, done.stdout) == (0, "started|")
    assert sorted(p.name for p in data.iterdir()) == sorted(INDEX_PLUGINS)
    for plugin in INDEX_PLUGINS:
        assert (data / plugin / "pit_index.json").read_bytes() == (OUT_DIR / "pit_index.json").read_bytes()
        for name in SETS:
            assert (data / plugin / name).read_bytes() == (OUT_DIR / name).read_bytes()
        assert sorted(p.name for p in (data / plugin).iterdir()) == ["mine_sets", "pit_index.json"]
        assert len(list((data / plugin / "mine_sets").iterdir())) == 15
    assert not (data / "RiftalCustody").exists()


@needs_script
@pytest.mark.parametrize("name", [set_name(3), set_name(14), CONTESTED, "pit_index.json"])
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


def committed_index() -> dict[str, Any]:
    return json.loads((OUT_DIR / "pit_index.json").read_text(encoding="utf-8"))


def test_a_bridge_carries_its_ends_deck_y_widths_and_landing() -> None:
    bridges = committed_index()["bridges"]
    assert len({b["name"] for b in bridges}) == 52
    for bridge in bridges:
        assert sorted(bridge) == ["bearing", "deck", "deck_y", "landing", "name", "terrace_end", "tower_end", "walk_width", "width"]
        assert bridge["landing"]["name"] == bridge["name"].replace("bridge", "landing")


def transit_at(index: dict[str, Any], points: np.ndarray) -> np.ndarray:
    """Which of ``points`` lie in any transit region; ``r`` is the pit radius from the origin's x and z."""
    held = np.zeros(len(points), dtype=bool)
    for region in index["transit"]:
        inside = ((points >= np.array(region["min"])) & (points <= np.array(region["max"]))).all(axis=1)
        if "r" in region:
            radius = np.hypot(points[:, 0] - index["origin"][0], points[:, 2] - index["origin"][2])
            inside &= (radius >= region["r"][0]) & (radius <= region["r"][1])
        held |= inside
    return held


def strip(bridge: dict[str, Any]) -> np.ndarray:
    """Every block from the tower end up to, not including, the terrace end, within half the width across, deck y to deck y + 3."""
    a, b = np.array(bridge["tower_end"])[[0, 2]], np.array(bridge["terrace_end"])[[0, 2]]
    length = float(np.hypot(*(b - a)))
    along = (b - a) / length
    low, high = np.minimum(a, b) - 8, np.maximum(a, b) + 8
    xs, zs = np.meshgrid(np.arange(low[0], high[0] + 1), np.arange(low[1], high[1] + 1))
    flat = np.stack([xs.ravel(), zs.ravel()], axis=1)
    reach, across = (flat - a) @ along, np.abs((flat - a) @ np.array([-along[1], along[0]]))
    kept = flat[(reach >= 0) & (reach < length) & (across <= bridge["width"] / 2)]
    return np.array([(x, y, z) for x, z in kept.tolist() for y in range(bridge["deck_y"], bridge["deck_y"] + 4)])


def test_no_transit_region_holds_a_bridge_strip() -> None:
    index = committed_index()
    for bridge in index["bridges"]:
        points = strip(bridge)
        held = transit_at(index, points)
        assert len(points) > 0
        assert not held.any(), f"{bridge['name']} has {int(held.sum())} blocks in transit, first at {points[held][0].tolist()}"


def test_transit_holds_both_ends_of_every_flight_the_gate_hall_and_the_first_decks_south_landing() -> None:
    index = committed_index()
    ends = np.array([s[end] for s in index["stairs"] for end in ("top", "bottom")])
    assert transit_at(index, ends).all()
    assert transit_at(index, np.array([index["warps"]["gate_hall"]["pos"], [0, 208, 109]])).all()


def test_the_open_pit_in_front_of_a_bay_and_the_middle_of_bridge_1_south_are_not_transit() -> None:
    assert not transit_at(committed_index(), np.array([[0, 208, 70], [0, 150, 80], [0, 208, 104]])).any()


def test_the_quarry_and_farm_doorways_are_disjoint_walk_in_boxes_inside_the_forecourt() -> None:
    index = committed_index()
    forecourt = index["gate"]["forecourt"]
    quarry, farm = index["doorways"]["portal_quarry"], index["doorways"]["portal_farm"]
    for door in (quarry, farm):
        assert door["world"] == "pit"
        assert all(forecourt["min"][i] <= door["min"][i] <= door["max"][i] <= forecourt["max"][i] for i in range(3))
        assert [door["max"][i] - door["min"][i] + 1 for i in range(3)] == [3, 3, 3]
    assert quarry["max"][0] < farm["min"][0]
