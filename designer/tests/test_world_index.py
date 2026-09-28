import json
from datetime import datetime
from pathlib import Path

import pytest

from designer import world_index
from designer.region import Bounds
from designer.world_index import Location, NamedRegion, WorldIndex

SPEC_WORLDS = {"mine_a", "mine_b", "mine_c", "lumber", "quarry", "farm", "contested", "plots"}
STAMP = "2026-09-07T12:00:00+00:00"


@pytest.fixture
def index() -> WorldIndex:
    return WorldIndex.load()


def test_committed_file_names_the_spec_worlds(index: WorldIndex) -> None:
    assert {w.name for w in index.worlds} == SPEC_WORLDS | {"design"}
    assert (index.version, index.default_world, index.world("design").role) == (1, "design", "design")
    # riots makes the lumber world a safe zone through this region's safe_zone tag.
    assert index.regions == [NamedRegion("lumber_safe_zone", "lumber", (-32, 40, -32), (31, 63, 31), ["mine", "safe_zone"])]
    assert {w.name: w.extra["rank"] for w in index.worlds if w.role == "ore_mine"} == {"mine_a": "A", "mine_b": "B", "mine_c": "C"}
    assert {(w.generator, w.seed) for w in index.worlds} == {("normal", 20260907)}
    assert index.resolve_pos("spawn") == (0, 64, 0) and index.locations_tagged("spawn")[0].world == "design"


def test_save_is_byte_stable_and_name_ordered(index: WorldIndex, tmp_path: Path) -> None:
    committed = world_index.DEFAULT_PATH.read_text(encoding="utf-8")
    assert index.save(tmp_path / "same.json", updated=index.updated).read_text(encoding="utf-8") == committed

    other = WorldIndex.load()
    index.add_location(Location("gate", "design", (1, 2, 3), 90, -10, ["npc"]))
    index.add_region(NamedRegion("yard", "mine_a", (9, 70, 9), (-4, 60, -4), ["mine"], {"rank": "A"}))
    other.add_region(NamedRegion("yard", "mine_a", (-4, 60, -4), (9, 70, 9), ["mine"], {"rank": "A"}))
    other.add_location(Location("gate", "design", (1, 2, 3), 90, -10, ["npc"]))
    first = index.save(tmp_path / "a.json", updated=STAMP).read_bytes()
    assert first == other.save(tmp_path / "b.json", updated=STAMP).read_bytes()
    assert first == WorldIndex.load(tmp_path / "a.json").save(tmp_path / "c.json", updated=STAMP).read_bytes()
    assert b"\r" not in first and first.endswith(b"}\n")
    assert [l.name for l in WorldIndex.load(tmp_path / "a.json").locations] == ["gate", "spawn"]

    index.save(tmp_path / "now.json")
    assert datetime.fromisoformat(index.updated).tzinfo is not None
    (tmp_path / "v2.json").write_text(committed.replace('"version": 1', '"version": 2'), encoding="utf-8")
    with pytest.raises(ValueError, match="version 2"):
        WorldIndex.load(tmp_path / "v2.json")


def test_resolve_pos_accepts_every_form(index: WorldIndex) -> None:
    index.add_region(NamedRegion("yard", "design", (9, 70, 9), (-4, 60, -4)))
    assert index.resolve_pos("spawn") == (0, 64, 0)
    assert index.resolve_pos("yard") == (3, 65, 3)
    assert index.resolve("yard").bounds == Bounds((-4, 60, -4), (9, 70, 9))
    assert Bounds.from_center(index.resolve_pos("yard"), index.resolve("yard").bounds.size) == index.resolve("yard").bounds
    assert index.resolve_pos("1,2,3") == (1, 2, 3)
    assert index.resolve_pos("-7, 12") == (-7, None, 12)
    assert index.resolve_pos([4, 5, 6]) == (4, 5, 6)
    for bad in ("1,2,3,4", "1,x", [1, 2]):
        with pytest.raises(ValueError):
            index.resolve_pos(bad)


def test_a_fractional_position_is_rejected_not_truncated(index: WorldIndex) -> None:
    assert index.resolve_pos([4.0, 5, -6.0]) == (4, 5, -6)
    for bad in ([-0.5, 64, 0], [1, 64.9, 2], [1, 2, float("nan")], [True, 2, 3], ["1", 2, 3]):
        with pytest.raises(ValueError, match="a position is three integers"):
            index.resolve_pos(bad)
    with pytest.raises(ValueError, match="a position is three integers"):
        Location("gate", "design", (-0.5, 64, 2))
    with pytest.raises(ValueError, match="a position is three integers"):
        NamedRegion("yard", "design", (0, 60, 0), (9, 70, -2.5))
    with pytest.raises(ValueError, match="a position is integers, got '-0.5,64,0'"):
        index.resolve_pos("-0.5,64,0")


def test_unknown_name_hints_the_nearest(index: WorldIndex) -> None:
    with pytest.raises(KeyError, match="no such name 'spwan', did you mean 'spawn'"):
        index.resolve("spwan")
    with pytest.raises(KeyError, match="no such world 'lumbre', did you mean 'lumber'"):
        index.world("lumbre")
    with pytest.raises(KeyError, match=r"no such name 'nothing_alike'\"?$"):
        index.resolve_pos("nothing_alike")


def test_names_are_unique_across_kinds(index: WorldIndex) -> None:
    index.add_location(Location("gate", "design", (1, 2, 3), tags=["npc"]))
    with pytest.raises(ValueError, match="'gate' is already defined"):
        index.add_region(NamedRegion("gate", "design", (0, 0, 0), (1, 1, 1)))
    with pytest.raises(ValueError, match="'gate' is already defined"):
        index.add_location(Location("gate", "design", (0, 0, 0)))
    index.add_region(NamedRegion("gate", "design", (0, 0, 0), (1, 1, 1), ["mine"]), replace=True)
    assert isinstance(index.resolve("gate"), NamedRegion) and index.locations_tagged("npc") == []
    for bad in ("Gate", "mine-a", "", "mine a"):
        with pytest.raises(ValueError, match="must match"):
            index.add_location(Location(bad, "design", (0, 0, 0)))
    with pytest.raises(KeyError, match="did you mean 'design'"):
        index.add_location(Location("far", "desgin", (0, 0, 0)))
    assert index.remove("gate").name == "gate" and index.names() == {"spawn": index.locations[0], "lumber_safe_zone": index.regions[0]}
    with pytest.raises(KeyError):
        index.remove("gate")


def test_preflight_returns_the_taken_names_and_raises_on_what_add_would_refuse(index: WorldIndex) -> None:
    gate = Location("gate", "design", (1, 2, 3)).to_json()
    spawn = Location("spawn", "design", (0, 64, 0)).to_json()
    yard = NamedRegion("lumber_safe_zone", "lumber", (0, 0, 0), (1, 1, 1)).to_json()
    assert index.preflight([gate, spawn], [yard]) == ["lumber_safe_zone", "spawn"]
    assert index.preflight([gate], []) == []
    with pytest.raises(ValueError, match="name 'Gate' must match"):
        index.preflight([gate, {**gate, "name": "Gate"}], [])
    with pytest.raises(KeyError, match="did you mean 'design'"):
        index.preflight([], [{**yard, "name": "far", "world": "desgin"}])
    with pytest.raises(ValueError, match="name 'gate' is given twice in one build"):
        index.preflight([gate], [{**yard, "name": "gate"}])


def test_load_enforces_the_add_invariants(index: WorldIndex, tmp_path: Path) -> None:
    gate = Location("gate", "design", (1, 2, 3)).to_json()
    for changes, message in (
        ({"regions": [NamedRegion("spawn", "design", (0, 0, 0), (1, 1, 1)).to_json()]}, "NamedRegion 'spawn' duplicates Location 'spawn'"),
        ({"locations": [{**gate, "name": "Gate"}]}, "Location 'Gate' must match"),
        ({"locations": [{**gate, "world": "desgin"}]}, "Location 'gate': no such world 'desgin', did you mean 'design'"),
        ({"default_world": "hub"}, "default_world 'hub' is not a listed world"),
    ):
        (tmp_path / "bad.json").write_text(json.dumps({**index.to_json(), **changes}), encoding="utf-8")
        with pytest.raises(ValueError, match=message):
            WorldIndex.load(tmp_path / "bad.json")


@pytest.mark.parametrize("refusal", [ValueError("rule_only_add_knows"), KeyError("rule_only_add_knows")], ids=["value", "key"])
def test_load_applies_every_rule_add_applies(index: WorldIndex, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, refusal: Exception) -> None:
    path = index.save(tmp_path / "index.json")

    def refuse(self: WorldIndex, entry: Location | NamedRegion, what: str | None = None) -> None:
        raise refusal

    monkeypatch.setattr(WorldIndex, "_admissible", refuse)
    with pytest.raises(ValueError, match="rule_only_add_knows"):
        WorldIndex.load(path)
    with pytest.raises(type(refusal), match="rule_only_add_knows"):
        index.add_location(Location("gate", "design", (0, 0, 0)))


def test_load_reports_a_bare_key_error_as_a_value_error(index: WorldIndex, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = index.save(tmp_path / "index.json")

    def refuse(self: WorldIndex, entry: Location | NamedRegion, what: str | None = None) -> None:
        raise KeyError()

    monkeypatch.setattr(WorldIndex, "_admissible", refuse)
    with pytest.raises(ValueError, match=r"^Location 'spawn': not admissible$"):
        WorldIndex.load(path)


def test_tag_queries(index: WorldIndex) -> None:
    index.add_region(NamedRegion("pit", "mine_a", (0, 0, 0), (3, 3, 3), ["mine", "safe_zone"]))
    index.add_location(Location("seller", "mine_a", (1, 1, 1), tags=["npc", "sell"]))
    assert [r.name for r in index.regions_tagged("safe_zone")] == ["lumber_safe_zone", "pit"] and index.regions_tagged("spawn") == []
    assert [l.name for l in index.locations_tagged("npc")] == ["seller"] and index.locations_tagged("mine") == []
    assert [l.name for l in index.locations_tagged("spawn")] == ["spawn"]


def test_select_filters_by_kind_and_tag_in_name_order(index: WorldIndex) -> None:
    index.add_location(Location("a_gate", "mine_a", (1, 1, 1), tags=["spawn"]))
    assert list(index.select()) == ["worlds", "locations", "regions"]
    assert [l["name"] for l in index.select(tag="spawn")["locations"]] == ["a_gate", "spawn"]
    assert set(index.select(tag="spawn")) == {"locations", "regions"}
    assert list(index.select("regions", "safe_zone")) == ["regions"]
    assert [w["name"] for w in index.select("worlds")["worlds"]] == sorted(w.name for w in index.worlds)
    with pytest.raises(ValueError, match="^worlds carry no tags"):
        index.select("worlds", "spawn")
    with pytest.raises(ValueError, match="^kind must be one of worlds, locations, regions, not 'save'$"):
        index.select("save")
