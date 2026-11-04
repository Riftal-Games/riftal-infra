import json

import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.checks import CheckSpec, load_checks
from designer.config import PROJECT_ROOT
from designer.edits import EditList, Fill
from designer.region import Region
from designer.verify import travel_time, warp_safe
from designer.world_index import Location, WorldIndex

ZONES = ("lumber", "mine_a", "mine_b", "mine_c")
STONE = "minecraft:stone"


def _built(zone: str):
    spec = MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / f"{zone}.json").read_text(encoding="utf-8")))
    geo = spec.geometry()
    box = geo.padding.union(geo.exit_platform).expand(2, "y")
    stone = EditList(spec.world, [Fill(box, STONE)]).to_region(Region.empty(spec.world, box))
    edits = build_mine(spec, Palette.load("mine_stone"))
    locations = {l["name"]: tuple(l["pos"]) for l in edits.extras["locations"]}
    return edits, edits.to_region(stone), locations


def _checks(kind: str, zone: str) -> list[CheckSpec]:
    return [s for s in load_checks() if s.kind == kind and s.zone == zone]


@pytest.mark.parametrize("zone", ("mine_b", "mine_c"))
def test_the_committed_index_carries_the_spawn_the_mine_builder_places(zone: str) -> None:
    arrival = WorldIndex.load().resolve(f"{zone}_spawn")
    assert isinstance(arrival, Location) and arrival.tags == ["spawn"] and arrival.world == zone
    assert all(type(c) is int for c in arrival.pos)
    built = _built(zone)[0].extras["locations"]
    assert arrival.to_json() == next(l for l in built if l["name"] == f"{zone}_spawn")


@pytest.mark.parametrize("zone", ("mine_b", "mine_c"))
def test_the_spawn_sits_on_the_platform_outside_the_reset_interior(zone: str) -> None:
    spec = MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / f"{zone}.json").read_text(encoding="utf-8")))
    spawn = WorldIndex.load().resolve_pos(f"{zone}_spawn")
    assert not spec.reset_interior().contains(spawn)
    # The feet stand one block above the platform's floor row.
    assert spec.geometry().exit_platform.contains((spawn[0], spawn[1] - 1, spawn[2]))


@pytest.mark.parametrize("zone", ZONES)
def test_warp_safe_passes_at_the_spawn_on_the_built_platform(zone: str) -> None:
    _, region, locations = _built(zone)
    (spec,) = _checks("warp_safe", zone)
    assert spec.args["at"] == f"{zone}_spawn"
    found = warp_safe(region, locations[spec.args["at"]])
    assert found.ok, f"{found.detail} {found.coords}"


@pytest.mark.parametrize("zone", ("mine_a", "mine_b", "mine_c"))
def test_travel_time_from_the_spawn_to_the_exit_is_within_the_default_limit(zone: str) -> None:
    _, region, locations = _built(zone)
    walk = next(s for s in _checks("travel_time", zone) if s.args["from"] == f"{zone}_spawn")
    assert walk.args["to"] == f"{zone}_exit"
    found = travel_time(region, locations[walk.args["from"]], locations[walk.args["to"]])
    assert found.ok and found.seconds < 10, found.detail
