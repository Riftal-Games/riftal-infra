"""``pit_matches_handoff``: each of plan 4.4's eleven checks fails by name, and a build through the fake bridge is gated by it."""

from __future__ import annotations

import gzip
import hashlib
import json
from collections.abc import Callable
from pathlib import Path

import pytest

from designer import checks as checks_mod
from designer import pit_census
from designer.bridge import Bridge
from designer.checks import CheckSpec, RunContext, check_world, load_checks, plan_fetches, run_one
from designer.level import LevelError, Saved, build_level, load_recipe, prepare_structures
from designer.pit_handoff import pit_matches_handoff
from designer.world_index import Location, WorldEntry, WorldIndex
from tests.fake_bridge import FakeBridge, FakeWorld
from tests.pit_fixture import BOX, CELLS, CENSUS, LADDERS, MUD, MUD_AT, ORIGIN, ROUTES, Pit, bed_colours, build, layout, structure_file, world

AIR, STONE, CLAY = "minecraft:air", "minecraft:stone", "minecraft:hardened_clay"
IRON_DOOR = "minecraft:iron_door[door_hinge_bit=false,minecraft:cardinal_direction=west,open_bit=false,upper_block_bit=false]"
LADDER_NORTH = "minecraft:ladder[facing_direction=2]"
WATER = "minecraft:water[liquid_depth=0]"
CELL_A, CELL_B = CELLS


def _set(pit: Pit, local: tuple[int, int, int], name: str) -> None:
    pit.region.set(*world(local), name)


def _walls_off_the_gate(pit: Pit) -> None:
    for x in range(-8, 9):
        for y in (2, 3, 4):
            _set(pit, (x, y, 80), STONE)


def _a_wrong_sample_in_the_data(pit: Pit) -> None:
    pit.ref.routes["stairs"][0]["bottom_landing"] = [11, 142, 121]


def _a_wrong_colour(pit: Pit) -> None:
    next(doc for doc in pit.docs.values() if "block_entities" in doc)["block_entities"][0]["color"] = 8


def _a_ladder_the_wrong_way(pit: Pit) -> None:
    _set(pit, (LADDERS[0]["x"], 144, LADDERS[0]["z"]), LADDER_NORTH)


# (check, what breaks it, text the failure names)
CASES: list[tuple[str, Callable[[Pit], None], str]] = [
    ("01_read_back", lambda p: p.region.set(3, 200, 3, STONE), "(3, 200, 3) holds minecraft:stone, the source has minecraft:air"),
    ("02_bed_placeholders", lambda p: p.region.set(*world(MUD_AT[0]), AIR), "packed_mud in layer 1: 2, expected 3"),
    ("03_placeholders_elsewhere", lambda p: p.region.set(3, 208, 112, MUD), "packed_mud at (3, 208, 112), outside every box"),
    ("04_contested_mine", lambda p: _set(p, (1, -117, 1), AIR), "terracotta in the contested mine: 17, expected 18, first missing at (1, -51, 1)"),
    ("04_contested_mine", lambda p: p.region.set(5, 216, 5, CLAY), "terracotta at (5, 216, 5), outside every box"),
    ("05_cells", lambda p: _set(p, tuple(CELL_A["chest"]), AIR), "cell L08-R2-010 chest at (80, 73, -26) holds minecraft:air, not a chest"),
    ("05_cells", lambda p: _set(p, tuple(CELL_B["light"]), "minecraft:lantern[hanging=true]"), "cell L09-R1-001 light at (76, 76, -15) holds minecraft:lantern[hanging=true], not a soul lantern"),
    ("05_cells", lambda p: _set(p, tuple(CELL_A["bed_foot"]), AIR), "cell L08-R2-010 bed_foot at (79, 73, -22) holds minecraft:air, not the foot of a bed"),
    ("05_cells", lambda p: _set(p, (78, 9, -24), STONE), "cell L08-R2-010 interior holds minecraft:stone at (78, 75, -24), not air"),
    ("05_cells", _a_wrong_colour, "has colour 8, not gray (7)"),
    ("06_census", lambda p: p.region.set(50, 208, 110, IRON_DOOR), "minecraft:iron_door: 5 in the world, 4 in the census, 4 from cells.json"),
    ("06_census", lambda p: p.region.set(50, 208, 110, IRON_DOOR), "at (50, 208, 110) belongs to no cell in cells.json"),
    ("07_ladders", lambda p: _set(p, (LADDERS[0]["x"], 144, LADDERS[0]["z"]), AIR), "layer 1 ladder at x -14 z 110: 1 of 5 blocks are not a ladder facing east, first minecraft:air at (-14, 210, 110)"),
    ("07_ladders", _a_ladder_the_wrong_way, "not a ladder facing east, first minecraft:ladder[facing_direction=2] at (-14, 210, 110)"),
    ("08_standable", lambda p: _set(p, (0, 143, 110), STONE), "warp rim_south at (0, 208, 110)"),
    ("08_standable", lambda p: _set(p, (12, 141, 104), AIR), "bridge 1 end_a at (12, 208, 104)"),
    ("09_walkable", _walls_off_the_gate, "gate_hall to terrace 8: no path"),
    ("10_samples", lambda p: _set(p, tuple(CELL_A["door_lower"]), AIR), "cell L08-R2-010 door_lower at (75, 73, -24) holds minecraft:air, not an iron door"),
    ("10_samples", _a_wrong_sample_in_the_data, "south stairway layer 1 bottom landing: the data has local (11, 142, 121)"),
    ("11_liquids", lambda p: p.region.set(20, 216, 20, WATER), "1 minecraft:water, the source has 0, first at (20, 216, 20)"),
]


def _failed(pit: Pit) -> dict[str, str]:
    found = pit_matches_handoff(pit.region, pit.ref, pit.docs)
    assert not found.ok
    return {part.partition(": ")[0].removeprefix("check "): part.partition(": ")[2] for part in found.detail.split("; check ")}


@pytest.fixture
def pit() -> Pit:
    return build()


def test_the_miniature_passes_all_eleven_and_reports_each_count(pit: Pit) -> None:
    found = pit_matches_handoff(pit.region, pit.ref, pit.docs)
    assert found.ok, found.detail
    counts = found.data["counts"]
    assert [name.partition("_")[0] for name in counts] == [f"{n:02d}" for n in range(1, 12)]
    assert counts["01_read_back"] == {"cells": BOX.volume, "mismatches": 0}
    assert counts["02_bed_placeholders"] == {"per_layer": {"layer 1": 3, "layer 2": 2}, "total": 5}
    assert counts["03_placeholders_elsewhere"] == {"count": 0}
    assert counts["04_contested_mine"] == {"in_cuboid": 18, "elsewhere": 0}
    assert counts["05_cells"] == {"cells": 2, "cells_ok": 2, "per_layer": {"8": 1, "9": 1}}
    assert counts["06_census"] == {"iron_door_halves": 4, "chests": 2, "beds": 4}
    assert counts["07_ladders"] == {"ladders": 1, "ladders_ok": 1}
    assert counts["08_standable"] == {"points": 12, "points_ok": 12}
    assert counts["09_walkable"] == {"legs": 7, "legs_ok": 7}
    assert counts["10_samples"] == {"samples": 3, "samples_ok": 3}
    assert counts["11_liquids"]["water"] == 0


@pytest.mark.parametrize(("check", "break_it", "names"), CASES, ids=[f"{c}-{i}" for i, (c, _, _) in enumerate(CASES)])
def test_each_check_fails_by_name(pit: Pit, check: str, break_it: Callable[[Pit], None], names: str) -> None:
    break_it(pit)
    failures = _failed(pit)
    assert check in failures
    assert names in failures[check]


def test_a_check_that_holds_is_not_named_when_another_fails(pit: Pit) -> None:
    pit.region.set(*world(MUD_AT[0]), AIR)
    assert "11_liquids" not in _failed(pit)


LADDER_TEXT = "layer 1 ladder at x -14 z 110: 1 of 5 blocks are not a ladder facing east, first minecraft:air at (-14, 210, 110)"


def _without_the_top_rung() -> Pit:
    placed = layout()
    del placed[world((LADDERS[0]["x"], 146, LADDERS[0]["z"]))]
    return build(placed)


def test_an_accepted_deviation_does_not_fail_and_is_counted() -> None:
    pit = _without_the_top_rung()
    found = pit_matches_handoff(pit.region, pit.ref, pit.docs, {"07_ladders": [LADDER_TEXT.replace("(-14, 210, 110)", "(-14, 212, 110)")]})
    assert found.ok, found.detail
    assert found.data["counts"]["07_ladders"] == {"ladders": 1, "ladders_ok": 0, "accepted_deviations": 1}
    assert not pit_matches_handoff(pit.region, pit.ref, pit.docs).ok


def test_an_accepted_deviation_that_is_no_longer_found_fails(pit: Pit) -> None:
    found = pit_matches_handoff(pit.region, pit.ref, pit.docs, {"07_ladders": ["layer 1 ladder at x 0 z 0: gone"]})
    assert not found.ok
    assert "accepted deviation not found: layer 1 ladder at x 0 z 0: gone" in found.detail


def test_a_worse_fault_on_an_accepted_ladder_is_not_accepted() -> None:
    pit = _without_the_top_rung()
    _set(pit, (LADDERS[0]["x"], 145, LADDERS[0]["z"]), AIR)
    found = pit_matches_handoff(pit.region, pit.ref, pit.docs, {"07_ladders": [LADDER_TEXT.replace("(-14, 210, 110)", "(-14, 212, 110)")]})
    assert not found.ok
    assert "07_ladders" in found.detail and "01_read_back" in found.detail


def test_a_failure_with_positions_hands_them_back(pit: Pit) -> None:
    pit.region.set(3, 208, 112, MUD)
    found = pit_matches_handoff(pit.region, pit.ref, pit.docs)
    assert (3, 208, 112) in found.coords


@pytest.mark.xfail(strict=True, reason="riftal-infra#1517: the check and its figures are still revision 1")
def test_the_committed_hand_off_carries_the_figures_of_plan_4_4() -> None:
    folder = pit_census.SOURCE_DIR
    routes, cells = json.loads((folder / "routes.json").read_text()), json.loads((folder / "cells.json").read_text())
    census = json.loads((folder / "census.json").read_text())["block_names"]
    beds = [level["bed_blocks"] for level in routes["levels"]]
    assert beds == [11757, 11004, 10249, 9634, 8720, 8186, 7269, 6419, 5888, 5217, 4115, 3724, 2953, 2260]
    assert sum(beds) == census["minecraft:packed_mud"] == 97395
    assert routes["contested_mine"]["blocks"] == census["minecraft:hardened_clay"] == 3200
    assert len(cells["cells"]) == 1869 and len(cells["ladders"]) == 111
    assert [sum(1 for c in cells["cells"] if c["layer"] == n) for n in range(1, 13)] == [234, 222, 204, 204, 174, 162, 144, 126, 123, 108, 96, 72]
    assert (len(routes["stairs"]), len(routes["warps"]), len(routes["bridges"])) == (56, 19, 4)
    assert census["minecraft:iron_door"] == 2 * 1869 and census["minecraft:chest"] == 1869 and census["minecraft:bed"] == 2 * 1869


def test_the_committed_check_gates_the_pit_and_reads_its_whole_box() -> None:
    specs = [s for s in load_checks() if s.kind == "pit_matches_handoff"]
    assert [(s.id, s.zone) for s in specs] == [("pit_matches_handoff", "pit")]
    index = WorldIndex.load()
    assert check_world(index, specs[0]) == "pit"
    recipe = load_recipe("pit")
    assert plan_fetches(specs, index)["pit"].bounds == recipe.bounds
    for name in specs[0].args["deviations"], specs[0].args["spec"]:
        assert (checks_mod.PROJECT_ROOT / name).is_file()


def test_every_committed_deviation_names_a_check_and_a_reason() -> None:
    data = json.loads((checks_mod.PROJECT_ROOT / "specs" / "pit_handoff_deviations.json").read_text())
    assert set(data) <= {"07_ladders", "08_standable", "09_walkable"}
    assert all(reason.strip() for texts in data.values() for reason in texts.values())


def test_a_check_naming_no_structure_spec_fails_rather_than_passes(pit: Pit, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checks_mod, "PROJECT_ROOT", tmp_path)
    spec = CheckSpec("p", "pit_matches_handoff", {"world": "zt", "spec": "specs/none.json"}, "zt")
    result = run_one(RunContext({"zt": pit.region}), _index(), spec)
    assert not result.ok
    assert "does not exist" in result.detail


# A build through the fake bridge: the source is a structure file, the fake writes what its cells hold, and the checks read it back.

RECIPE = {"generator": "normal", "seed": 7, "bounds": BOX.to_json(), "steps": [{"build": "structure", "spec": "specs/zt.json"}]}
SPEC = {
    "world": "zt", "source": "src", "file": "s.mcstructure.gz", "origin": list(ORIGIN), "min_corner": [-16, -118, -30], "substitutes": {},
}
CHECKS = (
    "version: 1\nchecks:\n  - check: pit_matches_handoff\n    id: pit_matches_handoff\n    zone: zt\n    world: zt\n    spec: specs/zt.json\n"
)


def _index() -> WorldIndex:
    return WorldIndex(default_world="zt", worlds=[WorldEntry("zt", "normal", 7, "pit")], locations=[Location("zt_spawn", "zt", (40, 64, 40))])


def _level(root: Path, fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, placed: dict[tuple[int, int, int], str]) -> None:
    raw = structure_file(placed, bed_colours())
    for folder in ("levels", "specs", "src"):
        (root / folder).mkdir()
    (root / "src" / "s.mcstructure.gz").write_bytes(gzip.compress(raw, mtime=0))
    pit_census.write_json(root / "src" / "pins.json", {"files": {}, "structure_sha256": hashlib.sha256(raw).hexdigest()})
    for name, data in (("cells.json", {"cells": CELLS, "ladders": LADDERS}), ("routes.json", ROUTES), ("census.json", CENSUS)):
        (root / "src" / name).write_text(json.dumps(data), encoding="utf-8")
    (root / "levels" / "zt.json").write_text(json.dumps(RECIPE), encoding="utf-8")
    (root / "specs" / "zt.json").write_text(json.dumps(SPEC), encoding="utf-8")
    (root / "checks.yaml").write_text(CHECKS, encoding="utf-8")
    (root / "mines.yml").write_text("worlds:\n  mine_x: worlds/mine_x.json\n", encoding="utf-8")
    fake.worlds["zt"] = FakeWorld(extent=((1000, 1000), (1001, 1001)))
    monkeypatch.setattr(checks_mod, "PROJECT_ROOT", root)


def _build(bridge: Bridge, fake: FakeBridge, root: Path) -> Path:
    converted = prepare_structures(load_recipe("zt", root), root, root / "out")
    fake.structure_dir = root / "out"
    return build_level(
        bridge, "zt", lambda: Saved("sha256:image", "bridge-commit", "toolkit-commit", 4096), root=root, index=_index(),
        checks_path=root / "checks.yaml", mines_config=root / "mines.yml", converted=converted,
    )


def test_a_clean_build_passes_the_gate_and_writes_every_count_into_the_lock(fake: FakeBridge, bridge: Bridge, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _level(tmp_path, fake, monkeypatch, layout())
    lock = json.loads(_build(bridge, fake, tmp_path).read_text(encoding="utf-8"))
    counts = lock["counts"]["pit_matches_handoff"]
    assert [name.partition("_")[0] for name in counts] == [f"{n:02d}" for n in range(1, 12)]
    assert counts["01_read_back"] == {"cells": BOX.volume, "mismatches": 0}
    assert counts["05_cells"]["cells_ok"] == 2


def test_a_build_with_one_cells_chest_moved_fails_naming_the_cell_and_leaves_no_lock(fake: FakeBridge, bridge: Bridge, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    placed = layout()
    chest = placed.pop(world(CELL_A["chest"]))
    placed[world([80, 7, -25])] = chest
    _level(tmp_path, fake, monkeypatch, placed)
    with pytest.raises(LevelError, match=r"cell L08-R2-010 chest at \(80, 73, -26\) holds minecraft:air, not a chest"):
        _build(bridge, fake, tmp_path)
    assert not (tmp_path / "levels" / "zt.lock.json").exists()


def test_a_build_with_one_stray_placeholder_on_a_walkway_fails_naming_its_position(fake: FakeBridge, bridge: Bridge, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    placed = layout()
    placed[world([3, 142, 112])] = MUD
    _level(tmp_path, fake, monkeypatch, placed)
    with pytest.raises(LevelError, match=r"packed_mud at \(3, 208, 112\), outside every box"):
        _build(bridge, fake, tmp_path)
    assert not (tmp_path / "levels" / "zt.lock.json").exists()
