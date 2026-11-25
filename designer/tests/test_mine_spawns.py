import json

import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.checks import CheckSpec, RunContext, load_checks, run_one
from designer.builders.stairs import StairsSpec
from designer.config import PROJECT_ROOT
from designer.edits import EditList, Fill
from designer.level import load_recipe
from designer.region import Region
from designer.world_index import Location, WorldIndex
from tests.test_lumber_access import _built as _lumber_built

ZONES = ("lumber", "mine_a", "mine_b", "mine_c", "quarry", "farm")
YARD_ZONES = ("lumber", "quarry", "farm")
STONE = "minecraft:stone"


def _spec(zone: str) -> MineSpec:
    return MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / f"{zone}.json").read_text(encoding="utf-8")))


def _built(zone: str):
    """The zone's edits, its built region and an index holding what the build registers beyond the committed file."""
    spec = _spec(zone)
    edits = build_mine(spec, Palette.load("mine_stone"))
    if zone in YARD_ZONES:
        # A yard's level is the mine plus the stairs that rise from the spawn, so its region is the whole recipe's.
        steps = [s for s in load_recipe(zone).steps if s.build == "stairs"]
        legs = [StairsSpec.from_dict(json.loads(PROJECT_ROOT.joinpath(s.spec).read_text(encoding="utf-8"))) for s in steps]
        region = _lumber_built(spec, legs)
    else:
        geo = spec.geometry()
        box = geo.padding.union(geo.exit_platform).expand(20, "xz").expand(8, "y")
        stone = EditList(spec.world, [Fill(box, STONE)]).to_region(Region.empty(spec.world, box))
        region = edits.to_region(stone)
    index = WorldIndex.load()
    index.register(
        [l for l in edits.extras["locations"] if not _committed(index, l["name"])],
        [r for r in edits.extras["regions"] if not _committed(index, r["name"])],
    )
    return edits, region, index


def _committed(index: WorldIndex, name: str) -> bool:
    try:
        index.resolve(name)
    except KeyError:
        return False
    return True


def _checks(kind: str, zone: str) -> list[CheckSpec]:
    return [s for s in load_checks() if s.kind == kind and s.zone == zone]


@pytest.mark.parametrize("zone", ("lumber", "mine_b", "mine_c", "quarry", "farm"))
def test_the_committed_index_carries_the_spawn_the_mine_builder_places(zone: str) -> None:
    arrival = WorldIndex.load().resolve(f"{zone}_spawn")
    assert isinstance(arrival, Location) and arrival.tags == ["spawn"] and arrival.world == zone
    assert all(type(c) is int for c in arrival.pos)
    built = _built(zone)[0].extras["locations"]
    assert arrival.to_json() == next(l for l in built if l["name"] == f"{zone}_spawn")


@pytest.mark.parametrize("zone", ("mine_b", "mine_c", "quarry", "farm"))
def test_the_spawn_sits_on_the_platform_outside_the_reset_interior(zone: str) -> None:
    spec = _spec(zone)
    spawn = WorldIndex.load().resolve_pos(f"{zone}_spawn")
    assert not spec.reset_interior().contains(spawn)
    # The feet stand one block above the platform's floor row.
    assert spec.geometry().exit_platform.contains((spawn[0], spawn[1] - 1, spawn[2]))


@pytest.mark.parametrize("zone", ZONES)
def test_warp_safe_passes_at_the_spawn_on_the_built_map(zone: str) -> None:
    _, region, index = _built(zone)
    (spec,) = _checks("warp_safe", zone)
    assert spec.args["at"] == f"{zone}_spawn"
    found = run_one(RunContext({zone: region}), index, spec)
    assert found.ok, f"{found.detail} {found.coords}"


@pytest.mark.parametrize("zone", ("mine_a", "mine_b", "mine_c", "quarry", "farm"))
def test_travel_time_from_the_spawn_to_the_exit_passes_at_the_configured_limit(zone: str) -> None:
    _, region, index = _built(zone)
    (walk,) = [s for s in _checks("travel_time", zone) if s.args["from"] == f"{zone}_spawn"]
    assert walk.args["to"] == f"{zone}_exit"
    found = run_one(RunContext({zone: region}), index, walk)
    assert found.ok, found.detail


def test_warp_safe_at_lumber_reads_the_stairs_ring_the_mine_alone_leaves_unbuilt() -> None:
    _, region, index = _built("lumber")
    x, y, z = index.resolve_pos("lumber_spawn")
    assert region.bounds.contains((x, y, z + 1))
    assert region.get(x, y, z + 1).startswith("minecraft:stone_brick_stairs")
