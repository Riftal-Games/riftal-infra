from pathlib import Path
from typing import Any

import pytest

from designer.bridge import Bridge
from designer.checks import check_world, load_checks, run_checks
from designer.custody import classify, offdisk_clear
from designer.world_index import WorldEntry, WorldIndex
from tests.fake_bridge import FakeBridge, FakeWorld

M1_ZONES = ("mine_a", "mine_b", "mine_c", "lumber")


def _entity(save_id: Any, pos: tuple[int, int, int] = (1, 64, 2)) -> dict[str, Any]:
    return {"kind": "entity", "chunk": [pos[0] >> 4, pos[2] >> 4], "pos": list(pos), "save_id": save_id}


@pytest.mark.parametrize("save_id", [
    "minecraft:item", "Item", "Arrow", "minecraft:arrow", "minecraft:thrown_trident", "ThrownTrident",
    "FallingSand", "minecraft:falling_block", "Painting", "minecraft:painting", 64, "83", 80 | 0x0C00,
])
def test_every_item_yielding_save_id_is_destroyed(save_id: Any) -> None:
    assert classify(save_id) == "yields an item"


@pytest.mark.parametrize("save_id", ["Human", "RiftalNpc", "minecraft:player", 63])
def test_a_saved_human_or_an_unregistered_id_cannot_be_ruled_out(save_id: Any) -> None:
    assert classify(save_id) is not None


@pytest.mark.parametrize("save_id", ["Snowball", "minecraft:xp_orb", "PrimedTNT", "minecraft:ice_bomb", "Zombie", "minecraft:squid"])
def test_an_entity_yielding_no_item_stays(save_id: str) -> None:
    assert classify(save_id) is None


def test_clean_findings_pass_and_tiles_are_not_item_4s() -> None:
    tile = {"kind": "tile", "chunk": [0, 0], "pos": [3, 64, 3], "save_id": "Chest"}
    found = offdisk_clear([tile, _entity("Snowball")])
    assert found.ok and found.detail.startswith("1 saved entities")


def test_a_painting_and_an_npc_fail_with_counts_and_positions() -> None:
    found = offdisk_clear([_entity("Painting", (5, 70, 5)), _entity("Painting", (6, 70, 5)), _entity("Human", (9, 65, 9))])
    assert not found.ok
    assert found.detail.startswith("3 of 3 saved entities fail ADR 013 item 4")
    assert "2 Painting (yields an item)" in found.detail and "1 Human (a Human whose" in found.detail
    assert found.coords == [(5, 70, 5), (6, 70, 5), (9, 65, 9)]


def _setup(tmp_path: Path, fake: FakeBridge, text: str) -> tuple[WorldIndex, list]:
    fake.worlds["mine_a"] = FakeWorld()
    worlds = [WorldEntry("design", "normal", 0, "design"), WorldEntry("mine_a", "normal", 0, "ore_mine")]
    index = WorldIndex(worlds=worlds, locations=[], regions=[])
    file = tmp_path / "checks.yaml"
    file.write_text(text, encoding="utf-8")
    return WorldIndex.load(index.save(tmp_path / "index.json")), load_checks(file)


TWO = "version: 1\nchecks:\n  - check: offdisk_clear\n    world: mine_a\n  - check: offdisk_clear\n    world: mine_a\n    id: again\n"


def test_run_scans_each_world_once_and_fails_on_a_dropped_item(fake: FakeBridge, bridge: Bridge, tmp_path: Path) -> None:
    index, specs = _setup(tmp_path, fake, TWO)
    fake.scan_findings = [_entity("minecraft:item", (4, 64, 4))]
    report = run_checks(bridge, index, specs)
    assert [r.id for r in report.failed] == ["offdisk_clear_mine_a", "again"]
    assert report.results[0].coords == [(4, 64, 4)]
    assert [r["args"] for r in fake.requests if r["op"] == "scan_items"] == [{"world": "mine_a"}]


def test_run_passes_a_clean_world(fake: FakeBridge, bridge: Bridge, tmp_path: Path) -> None:
    index, specs = _setup(tmp_path, fake, TWO)
    assert not run_checks(bridge, index, specs).failed


def test_an_unindexed_world_fails_without_a_scan(fake: FakeBridge, bridge: Bridge, tmp_path: Path) -> None:
    index, specs = _setup(tmp_path, fake, "version: 1\nchecks:\n  - check: offdisk_clear\n    world: mars\n")
    assert check_world(index, specs[0]) is None
    (result,) = run_checks(bridge, index, specs).results
    assert not result.ok and "mars" in result.detail
    assert not [r for r in fake.requests if r["op"] == "scan_items"]


@pytest.mark.parametrize("zone", M1_ZONES)
def test_checks_yaml_holds_every_m1_zone_to_item_4(zone: str) -> None:
    held = [s for s in load_checks() if s.kind == "offdisk_clear" and s.zone == zone]
    assert [s.args["world"] for s in held] == [zone]
