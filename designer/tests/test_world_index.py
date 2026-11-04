import json
import re
from datetime import datetime
from pathlib import Path

import pytest

from designer import world_index
from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT
from designer.region import Bounds
from designer.world_index import Location, NamedRegion, WorldEntry, WorldIndex

SPEC_WORLDS = {"mine_a", "mine_b", "mine_c", "lumber", "quarry", "farm", "contested", "plots"}
STAMP = "2026-09-07T12:00:00+00:00"


@pytest.fixture
def index() -> WorldIndex:
    return WorldIndex.load()


def test_committed_file_names_the_spec_worlds(index: WorldIndex) -> None:
    assert {w.name for w in index.worlds} == SPEC_WORLDS | {"design"}
    assert (index.version, index.default_world, index.world("design").role) == (1, "design", "design")
    # riots makes a world a safe zone through a region's safe_zone tag. A ranked mine's region is its reset interior.
    mines = [NamedRegion(f"mine_{m}_safe_zone", f"mine_{m}", (-16, 40, -16), (15, 50, 15), ["mine", "safe_zone"]) for m in "abc"]
    assert index.regions == [NamedRegion("lumber_safe_zone", "lumber", (-32, 40, -32), (31, 63, 31), ["mine", "safe_zone"]), *mines]
    assert {w.name: w.extra["rank"] for w in index.worlds if w.role == "ore_mine"} == {"mine_a": "A", "mine_b": "B", "mine_c": "C"}
    assert {(w.generator, w.seed) for w in index.worlds if w.name not in ("lumber", "mine_a")} == {("normal", 20260907)}
    assert {(index.world(n).generator, index.world(n).seed) for n in ("lumber", "mine_a")} == {("normal", 23)}
    assert index.resolve_pos("spawn") == (256, 70, 256)
    assert [(l.name, l.world) for l in index.locations_tagged("spawn")] == [("lumber_spawn", "lumber"), ("mine_a_spawn", "mine_a"), ("mine_b_spawn", "mine_b"), ("mine_c_spawn", "mine_c"), ("spawn", "design")]


def test_the_rankup_location_is_what_the_mine_builder_places_and_ranks_accepts(index: WorldIndex) -> None:
    # RiftalRanks opens a rank-up at a rankup-tagged location with a string world and a position of
    # three integers (RankupMarkers). The sign stands only where the mine builder puts it, and a
    # level build refuses a committed entry it does not reproduce exactly.
    rankup = index.locations_tagged("rankup")
    assert [l.name for l in rankup] == ["rankup_npc_a"]
    assert index.world(rankup[0].world).extra["rank"] == "A"
    spec = MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8")))
    built = build_mine(spec, Palette.load("mine_stone")).extras["locations"]
    assert rankup[0].to_json() == next(l for l in built if l["name"] == "rankup_npc_a")
    assert all(type(c) is int for c in rankup[0].pos) and len(rankup[0].pos) == 3


def test_the_sell_location_is_what_the_mine_builder_places_and_economy_accepts(index: WorldIndex) -> None:
    # RiftalEconomy opens the sell shop at each sell-tagged location with a non-empty string world and a
    # position of exactly three integers (SellLocations). The sign stands only where the mine builder puts
    # it, and a level build refuses a committed entry it does not reproduce exactly.
    sell = index.locations_tagged("sell")
    assert [l.name for l in sell] == ["sell_npc_a"]
    assert index.world(sell[0].world).extra["rank"] == "A"
    spec = MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8")))
    built = build_mine(spec, Palette.load("mine_stone")).extras["locations"]
    assert sell[0].to_json() == next(l for l in built if l["name"] == "sell_npc_a")
    assert sell[0].world != "" and len(sell[0].pos) == 3 and all(type(c) is int for c in sell[0].pos)


def test_the_lumber_arrival_is_what_the_mine_builder_places_at_the_stairway_foot(index: WorldIndex) -> None:
    # A join teleport or a travel route names a location, and lumber's own level spawn is a flooded cave
    # 360 blocks from the yard (riftal-infra#1355). The entry stands only where the mine builder puts it,
    # and a level build refuses a committed entry it does not reproduce exactly.
    arrival = index.resolve("lumber_spawn")
    assert isinstance(arrival, Location) and arrival.tags == ["spawn"]
    assert arrival.world == "lumber" and arrival.pos == (0, 40, 16)
    assert all(type(c) is int for c in arrival.pos)
    spec = MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / "lumber.json").read_text(encoding="utf-8")))
    built = build_mine(spec, Palette.load("mine_stone")).extras["locations"]
    assert arrival.to_json() == next(l for l in built if l["name"] == "lumber_spawn")


def test_the_mine_a_arrival_is_what_the_mine_builder_places_at_the_exit_lane_end(index: WorldIndex) -> None:
    # The join teleport names this location, and a level build refuses a committed entry it does not
    # reproduce exactly (riftal-infra#319).
    arrival = index.resolve("mine_a_spawn")
    assert isinstance(arrival, Location) and arrival.tags == ["spawn"]
    assert arrival.world == "mine_a" and arrival.pos == (0, 40, 23)
    assert all(type(c) is int for c in arrival.pos)
    spec = MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8")))
    built = build_mine(spec, Palette.load("mine_stone")).extras["locations"]
    assert arrival.to_json() == next(l for l in built if l["name"] == "mine_a_spawn")


def test_design_spawn_sits_on_chunks_a_fresh_level_generates(index: WorldIndex) -> None:
    # PocketMine creates a level with its spawn at (256, 70, 256) and generates only a
    # radius of 8 chunks around it (WorldCreationOptions, WorldManager::generateWorld).
    # A spawn outside that area reads as ungenerated chunks until someone runs pregen.
    boot_chunk, safe_offset = (256 >> 4, 256 >> 4), 4
    x, _, z = index.resolve_pos("spawn")
    assert index.resolve("spawn").world == index.default_world == "design"
    assert max(abs((x >> 4) - boot_chunk[0]), abs((z >> 4) - boot_chunk[1])) <= safe_offset


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
    assert [l.name for l in WorldIndex.load(tmp_path / "a.json").locations] == ["gate", "lumber_spawn", "mine_a_spawn", "mine_b_spawn", "mine_c_spawn", "rankup_npc_a", "sell_npc_a", "spawn"]

    index.save(tmp_path / "now.json")
    assert datetime.fromisoformat(index.updated).tzinfo is not None
    (tmp_path / "v2.json").write_text(committed.replace('"version": 1', '"version": 2'), encoding="utf-8")
    with pytest.raises(ValueError, match="version 2"):
        WorldIndex.load(tmp_path / "v2.json")


def test_resolve_pos_accepts_every_form(index: WorldIndex) -> None:
    index.add_region(NamedRegion("yard", "design", (9, 70, 9), (-4, 60, -4)))
    assert index.resolve_pos("spawn") == (256, 70, 256)
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
    assert isinstance(index.resolve("gate"), NamedRegion) and [l.name for l in index.locations_tagged("npc")] == ["rankup_npc_a", "sell_npc_a"]
    for bad in ("Gate", "mine-a", "", "mine a"):
        with pytest.raises(ValueError, match="must match"):
            index.add_location(Location(bad, "design", (0, 0, 0)))
    with pytest.raises(KeyError, match="did you mean 'design'"):
        index.add_location(Location("far", "desgin", (0, 0, 0)))
    assert index.remove("gate").name == "gate" and index.names() == {**{l.name: l for l in index.locations}, **{r.name: r for r in index.regions}}
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


def _contested_mine_regions(**changes: object) -> list[dict]:
    data = {**json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8")), "name": "contested_mine", "world": "contested"}
    data.pop("safe_zone")
    return build_mine(MineSpec.from_dict({**data, **changes}), Palette.load("mine_stone")).extras["regions"]


def test_preflight_refuses_a_contested_mine_spec_that_leaves_safe_zone_at_its_default(index: WorldIndex) -> None:
    with pytest.raises(ValueError, match=r"^region 'contested_mine' carries safe_zone in 'contested', a contested world that is always PvP;"):
        index.preflight([], _contested_mine_regions())
    with pytest.raises(ValueError, match="carries safe_zone"):
        index.preflight([], _contested_mine_regions(safe_zone=True))
    assert index.preflight([], _contested_mine_regions(safe_zone=False)) == []


def test_a_contested_world_refuses_a_safe_zone_region_on_add_and_load(index: WorldIndex, tmp_path: Path) -> None:
    pit = NamedRegion("pit", "contested", (0, 0, 0), (3, 3, 3), ["mine", "safe_zone"])
    with pytest.raises(ValueError, match="region 'pit' carries safe_zone in 'contested'"):
        index.add_region(pit)
    (tmp_path / "bad.json").write_text(json.dumps({**index.to_json(), "regions": [pit.to_json()]}), encoding="utf-8")
    with pytest.raises(ValueError, match="^NamedRegion 'pit' carries safe_zone in 'contested'"):
        WorldIndex.load(tmp_path / "bad.json")
    index.add_region(NamedRegion("pit", "contested", (0, 0, 0), (3, 3, 3), ["mine"]))
    index.add_region(NamedRegion("yard", "mine_a", (0, 0, 0), (3, 3, 3), ["mine", "safe_zone"]))



def test_the_safe_zone_refusal_follows_the_world_role_not_its_name() -> None:
    index = WorldIndex(worlds=[WorldEntry("arena", "normal", 0, "contested"), WorldEntry("contested", "normal", 0, "ore_mine")])
    with pytest.raises(ValueError, match="region 'pit' carries safe_zone in 'arena'"):
        index.add_region(NamedRegion("pit", "arena", (0, 0, 0), (3, 3, 3), ["mine", "safe_zone"]))
    index.add_region(NamedRegion("yard", "contested", (0, 0, 0), (3, 3, 3), ["mine", "safe_zone"]))

def test_register_refuses_a_taken_name_unless_replace(index: WorldIndex) -> None:
    moved = Location("spawn", "design", (5, 64, 5)).to_json()
    with pytest.raises(ValueError, match="'spawn' is already defined"):
        index.register([moved], [])
    assert index.resolve("spawn").pos == (256, 70, 256)
    index.register([moved], [], replace=True)
    assert index.resolve("spawn").pos == (5, 64, 5)


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


def test_load_reports_an_unreadable_file_as_an_index_file_error(tmp_path: Path) -> None:
    for path in (tmp_path / "missing.json", tmp_path):
        with pytest.raises(world_index.IndexFileError, match=rf"^cannot read the world index {re.escape(str(path))}: \S"):
            WorldIndex.load(path)


def test_load_reports_a_bare_key_error_as_a_value_error(index: WorldIndex, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = index.save(tmp_path / "index.json")

    def refuse(self: WorldIndex, entry: Location | NamedRegion, what: str | None = None) -> None:
        raise KeyError()

    monkeypatch.setattr(WorldIndex, "_admissible", refuse)
    with pytest.raises(ValueError, match=r"^Location 'lumber_spawn': not admissible$"):
        WorldIndex.load(path)


def test_tag_queries(index: WorldIndex) -> None:
    index.add_region(NamedRegion("pit", "mine_a", (0, 0, 0), (3, 3, 3), ["mine", "safe_zone"]))
    index.add_location(Location("seller", "mine_a", (1, 1, 1), tags=["npc", "sell"]))
    assert [r.name for r in index.regions_tagged("safe_zone")] == ["lumber_safe_zone", "mine_a_safe_zone", "mine_b_safe_zone", "mine_c_safe_zone", "pit"] and index.regions_tagged("spawn") == []
    assert [l.name for l in index.locations_tagged("npc")] == ["rankup_npc_a", "sell_npc_a", "seller"] and index.locations_tagged("mine") == []
    assert [l.name for l in index.locations_tagged("spawn")] == ["lumber_spawn", "mine_a_spawn", "mine_b_spawn", "mine_c_spawn", "spawn"]


def test_select_filters_by_kind_and_tag_in_name_order(index: WorldIndex) -> None:
    index.add_location(Location("a_gate", "mine_a", (1, 1, 1), tags=["spawn"]))
    index.add_location(Location("b_seller", "mine_a", (2, 2, 2), tags=["npc"]))
    index.add_location(Location("c_post", "mine_a", (3, 3, 3)))
    index.add_region(NamedRegion("a_pit", "mine_a", (0, 0, 0), (3, 3, 3), ["mine"]))
    index.add_region(NamedRegion("b_yard", "mine_a", (0, 0, 0), (3, 3, 3)))
    assert list(index.select()) == ["worlds", "locations", "regions"]
    by_spawn = index.select(tag="spawn")
    assert list(by_spawn) == ["locations", "regions"]
    assert [l["name"] for l in by_spawn["locations"]] == ["a_gate", "lumber_spawn", "mine_a_spawn", "mine_b_spawn", "mine_c_spawn", "spawn"] and by_spawn["regions"] == []
    assert list(index.select("regions", "safe_zone")) == ["regions"]
    assert [r["name"] for r in index.select("regions", "safe_zone")["regions"]] == ["lumber_safe_zone", "mine_a_safe_zone", "mine_b_safe_zone", "mine_c_safe_zone"]
    assert [r["name"] for r in index.select("regions", "mine")["regions"]] == ["a_pit", "lumber_safe_zone", "mine_a_safe_zone", "mine_b_safe_zone", "mine_c_safe_zone"]
    assert [w["name"] for w in index.select("worlds")["worlds"]] == sorted(w.name for w in index.worlds)
    with pytest.raises(ValueError, match="^worlds carry no tags"):
        index.select("worlds", "spawn")
    with pytest.raises(ValueError, match="^kind must be one of worlds, locations, regions, not 'save'$"):
        index.select("save")


@pytest.mark.parametrize("kind", ["locations", "regions"])
@pytest.mark.parametrize("tag", [1, True, None, ["safe_zone"]])
def test_load_refuses_an_entry_with_a_tag_that_is_not_a_string(index: WorldIndex, tmp_path: Path, kind: str, tag: object) -> None:
    data = index.to_json()
    data[kind][0]["tags"] = ["mine", tag]
    (tmp_path / "bad.json").write_text(json.dumps(data), encoding="utf-8")
    name = data[kind][0]["name"]
    with pytest.raises(ValueError, match=f"^{'Location' if kind == 'locations' else 'NamedRegion'} '{name}' has a tag that is not a string"):
        WorldIndex.load(tmp_path / "bad.json")


@pytest.mark.parametrize("kind", ["locations", "regions"])
@pytest.mark.parametrize("tags", ["safe_zone", {"safe_zone": True}, 1])
def test_load_refuses_an_entry_whose_tags_are_not_a_list(index: WorldIndex, tmp_path: Path, kind: str, tags: object) -> None:
    data = index.to_json()
    data[kind][0]["tags"] = tags
    (tmp_path / "bad.json").write_text(json.dumps(data), encoding="utf-8")
    name = data[kind][0]["name"]
    with pytest.raises(ValueError, match=f"^{'Location' if kind == 'locations' else 'NamedRegion'} '{name}' has tags that are not a list: {re.escape(repr(tags))}$"):
        WorldIndex.load(tmp_path / "bad.json")


PROBES = {
    "locations": {"name": "probe", "world": "design", "pos": [1, 2, 3]},
    "regions": {"name": "probe", "world": "design", "min": [0, 0, 0], "max": [1, 1, 1]},
}


def _write(index: WorldIndex, path: str, kind: str, entry: dict[str, object]) -> None:
    locations, regions = ([entry], []) if kind == "locations" else ([], [entry])
    if path == "add" and kind == "locations":
        index.add_location(Location.from_json(entry))
    elif path == "add":
        index.add_region(NamedRegion.from_json(entry))
    elif path == "register":
        index.register(locations, regions)
    else:
        index.preflight(locations, regions)


@pytest.mark.parametrize("path", ["add", "register", "preflight"])
@pytest.mark.parametrize("kind", ["locations", "regions"])
@pytest.mark.parametrize(
    ("tags", "refusal"),
    [
        ("safe_zone", "has tags that are not a list: 'safe_zone'"),
        ({"safe_zone": True}, "has tags that are not a list: {'safe_zone': True}"),
        (1, "has tags that are not a list: 1"),
        (["mine", 1], "has a tag that is not a string: 1"),
        (["mine", None], "has a tag that is not a string: None"),
    ],
)
def test_every_write_path_refuses_tags_the_plugins_cannot_match(index: WorldIndex, path: str, kind: str, tags: object, refusal: str) -> None:
    before = index.to_json()
    with pytest.raises(ValueError, match=f"^{'Location' if kind == 'locations' else 'NamedRegion'} 'probe' {re.escape(refusal)}$"):
        _write(index, path, kind, {**PROBES[kind], "tags": tags})
    assert index.to_json() == before


@pytest.mark.parametrize("path", ["add", "register", "preflight"])
@pytest.mark.parametrize("kind", ["locations", "regions"])
def test_every_write_path_admits_a_list_of_string_tags(index: WorldIndex, path: str, kind: str) -> None:
    _write(index, path, kind, {**PROBES[kind], "tags": ["mine", "safe_zone"]})
    assert path == "preflight" or index.resolve("probe").tags == ["mine", "safe_zone"]
