from pathlib import Path

import pytest

from designer.bridge import Bridge
from designer.checks import CheckSpec, Fetch, RunContext, load_checks, plan_fetches, run_checks, run_one, write_report
from designer.region import Bounds
from designer.world_index import Location, NamedRegion, WorldEntry, WorldIndex
from tests.fake_bridge import FakeBridge, FakeWorld

CHECKS = """
version: 1
defaults:
  corridor_margin: 4
checks:
  - check: travel_time
    from: a
    to: b
  - check: warp_safe
    at: void
    id: warp_void
"""


def _index(path: Path) -> WorldIndex:
    index = WorldIndex(
        worlds=[WorldEntry("design", "normal", 0, "design"), WorldEntry("mine_a", "normal", 0, "ore_mine")],
        locations=[Location("a", "design", (10, 64, 10)), Location("b", "design", (20, 64, 20)), Location("far", "design", (100, 64, 100)),
                   Location("void", "design", (-40, 64, -40)), Location("c", "mine_a", (0, 64, 0))],
        regions=[NamedRegion("box", "mine_a", (0, 60, 0), (9, 69, 9))],
    )
    return WorldIndex.load(index.save(path / "index.json"))


def _checks(path: Path, text: str) -> list[CheckSpec]:
    file = path / "checks.yaml"
    file.write_text(text, encoding="utf-8")
    return load_checks(file)


def test_load_fills_defaults_and_ids(tmp_path: Path) -> None:
    travel, warp = _checks(tmp_path, CHECKS)
    assert travel.id == "travel_time_a_b" and travel.kind == "travel_time"
    assert travel.args == {"from": "a", "to": "b", "margin": 4, "speed": 4.317, "max_seconds": 10}
    assert warp.id == "warp_void" and warp.args == {"at": "void"}


def test_load_rejects_a_missing_parameter(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match=r"check 0 \(travel_time\) is missing \['to'\]"):
        _checks(tmp_path, "version: 1\nchecks:\n  - check: travel_time\n    from: a\n")


def test_plan_unions_a_world_and_separates_another(tmp_path: Path) -> None:
    index = _index(tmp_path)
    plan = plan_fetches([
        CheckSpec("t", "travel_time", {"from": "a", "to": "b", "margin": 4}), CheckSpec("w", "warp_safe", {"at": "void"}),
        CheckSpec("e", "entity_clear", {"at": "c"}), CheckSpec("l", "light_ok", {"region": "box", "min_level": 8}),
    ], index)
    assert plan["design"] == Fetch(Bounds((-43, 56, -43), (24, 72, 24)))
    assert plan["mine_a"] == Fetch(Bounds((-3, 60, -3), (9, 69, 9)), light=True)


def test_run_fetches_once_and_reports_both_outcomes(fake: FakeBridge, bridge: Bridge, tmp_path: Path) -> None:
    index, checks = _index(tmp_path), _checks(tmp_path, CHECKS)
    report = run_checks(bridge, index, checks)
    assert len([r for r in fake.requests if r["op"] == "get_region"]) == 1
    travel, warp = report.results
    assert travel.ok and travel.check == "travel_time" and "blocks in" in travel.detail
    assert not warp.ok and warp.coords == [(-40, 63, -40)] and report.failed == [warp]
    text = write_report(report, tmp_path / "out" / "report.md").read_text(encoding="utf-8")
    assert "1 passed, 1 failed of 2." in text
    assert "| travel_time_a_b | travel_time | yes |" in text and "| warp_void | warp_safe | no |" in text
    assert "## Failures" in text and "### warp_void" in text and "- -40, 63, -40" in text
    assert [r.id for r in run_checks(bridge, index, checks, only=["warp_void"]).results] == ["warp_void"]


def test_position_outside_the_fetched_union_fails_the_check(bridge: Bridge, tmp_path: Path) -> None:
    ctx = RunContext.fetch(bridge, {"design": Fetch(Bounds((0, 60, 0), (30, 70, 30)))})
    result = run_one(ctx, _index(tmp_path), CheckSpec("w", "warp_safe", {"at": "far"}))
    assert not result.ok and "(100, 64, 100) is outside the fetched" in result.detail


def test_missing_mine_spec_file_fails_the_check(tmp_path: Path) -> None:
    spec = CheckSpec("m", "mine_valid", {"region": "box", "spec": "specs/nope.json"})
    result = run_one(RunContext({}), _index(tmp_path), spec)
    assert not result.ok and result.detail.endswith("nope.json does not exist")


def test_no_holes_fails_a_fractional_floor_y_instead_of_truncating_it(fake: FakeBridge, bridge: Bridge, tmp_path: Path) -> None:
    fake.worlds["mine_a"] = FakeWorld()
    ctx = RunContext.fetch(bridge, {"mine_a": Fetch(Bounds((0, 59, 0), (9, 70, 9)))})
    result = run_one(ctx, _index(tmp_path), CheckSpec("h", "no_holes", {"region": "box", "floor_y": -0.5}))
    assert not result.ok and result.detail == "floor_y must be an integer, got -0.5"


@pytest.mark.parametrize("kind, args, field", [
    ("path_exists", {"from": "c", "to": "c", "margin": 1.5}, "margin"),
    ("path_exists", {"from": "c", "to": "c", "margin": 1, "max_drop": 1.5}, "max_drop"),
    ("travel_time", {"from": "c", "to": "c", "margin": 1.5, "speed": 4.3, "max_seconds": 10}, "margin"),
    ("travel_time", {"from": "c", "to": "c", "margin": 1, "max_drop": 1.5, "speed": 4.3, "max_seconds": 10}, "max_drop"),
    ("light_ok", {"region": "box", "min_level": 1.5}, "min_level"),
])
def test_a_fractional_count_fails_the_check_instead_of_truncating_it(
    fake: FakeBridge, bridge: Bridge, tmp_path: Path, kind: str, args: dict, field: str,
) -> None:
    fake.worlds["mine_a"] = FakeWorld()
    ctx = RunContext.fetch(bridge, {"mine_a": Fetch(Bounds((0, 50, 0), (9, 75, 9)), light=True)})
    result = run_one(ctx, _index(tmp_path), CheckSpec("n", kind, args))
    assert not result.ok and result.detail == f"{field} must be an integer, got 1.5"
