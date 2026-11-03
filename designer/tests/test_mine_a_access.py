import json

import pytest
import yaml

from designer.blocks import AIR
from designer.builders.base import DIRS, Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.builders.stairs import StairsSpec, build_stairs
from designer.checks import DEFAULT_PATH as CHECKS
from designer.config import PROJECT_ROOT
from designer.level import load_recipe, pregen_bounds
from designer.region import Bounds, Region
from designer.verify import path_exists

STONE = "minecraft:stone"
# The top block of seed 23's grass east of the stairs' last tread, read from the built level's heightmap.
# A tread at y 63 tops out at 64.0, flush with that grass, so the exit needs no jump.
EXIT_GROUND_Y = 63


def _json(*parts: str) -> dict:
    return json.loads(PROJECT_ROOT.joinpath(*parts).read_text(encoding="utf-8"))


@pytest.fixture
def mine() -> MineSpec:
    return MineSpec.from_dict(_json("specs", "mine_a.json"))


@pytest.fixture
def legs() -> list[StairsSpec]:
    steps = [step for step in load_recipe("mine_a").steps if step.build == "stairs"]
    return [StairsSpec.from_dict(_json(*step.spec.split("/"))) for step in steps]


def _top(leg: StairsSpec) -> tuple[int, int, int]:
    dx, dz = DIRS[leg.direction]
    return leg.base[0] + dx * leg.rise, leg.base[1] + leg.rise, leg.base[2] + dz * leg.rise


def _spawn(mine: MineSpec) -> tuple[int, int, int]:
    locations = build_mine(mine, Palette.load("mine_stone")).extras["locations"]
    return tuple(next(l for l in locations if l["name"] == "mine_a_spawn")["pos"])


def _goal(legs: list[StairsSpec]) -> tuple[int, int, int]:
    """Standing room on the ground two cells past the last tread."""
    dx, dz = DIRS[legs[-1].direction]
    x, _, z = _top(legs[-1])
    return x + 2 * dx, EXIT_GROUND_Y + 1, z + 2 * dz


def _built(mine: MineSpec, legs: list[StairsSpec], with_legs: bool = True) -> Region:
    """The mine and its stairs dug into stone that reaches the exit's ground, over the chunks ``pregen`` populates."""
    palette = Palette.load("mine_stone")
    recipe = Bounds.from_json(_json("levels", "mine_a.json")["bounds"])
    area = pregen_bounds(recipe)
    region = Region.empty("mine_a", Bounds((area.min[0], recipe.min[1], area.min[1]), (area.max[0], EXIT_GROUND_Y + 3, area.max[1])))
    region.fill(Bounds(region.bounds.min, (region.bounds.max[0], EXIT_GROUND_Y, region.bounds.max[2])), STONE)
    region = build_mine(mine, palette).to_region(region)
    for leg in legs if with_legs else ():
        region = build_stairs(leg, palette).to_region(region)
    return region


def test_the_legs_chain_from_the_spawn_and_stay_in_the_populated_chunks(mine: MineSpec, legs: list[StairsSpec]) -> None:
    x, y, z = _spawn(mine)
    assert legs and all(leg.world == mine.world for leg in legs)
    assert legs[0].direction == mine.entrance.side and legs[0].base == (x, y - 1, z)
    for before, after in zip(legs, legs[1:]):
        assert after.base == _top(before)
    area = pregen_bounds(Bounds.from_json(_json("levels", "mine_a.json")["bounds"]))
    for leg in legs:
        for tread in (leg.base, _top(leg)):
            for lateral in (-(leg.width // 2), leg.width - 1 - leg.width // 2):
                dx, dz = DIRS[leg.direction]
                assert area.contains((tread[0] + abs(dz) * lateral, tread[2] + abs(dx) * lateral))


def test_the_recipe_bounds_are_the_mines_own_box(mine: MineSpec) -> None:
    # Stone beside the exit lane is natural terrain, and its dirt and gravel pockets differ from one build to the next.
    assert Bounds.from_json(_json("levels", "mine_a.json")["bounds"]) == mine.geometry().outer


def test_the_last_tread_is_flush_with_seed_23s_ground_at_the_exit(legs: list[StairsSpec]) -> None:
    assert load_recipe("mine_a").seed == 23
    assert _top(legs[-1])[1] == EXIT_GROUND_Y


def test_the_stairs_carry_a_walker_from_the_spawn_onto_the_ground(mine: MineSpec, legs: list[StairsSpec]) -> None:
    found = path_exists(_built(mine, legs), _spawn(mine), _goal(legs))
    assert found.ok, found.detail


def test_the_mine_alone_leaves_the_spawn_sealed_under_the_ground(mine: MineSpec, legs: list[StairsSpec]) -> None:
    sealed = path_exists(_built(mine, legs, with_legs=False), _spawn(mine), _goal(legs))
    assert (sealed.ok, sealed.detail) == (False, "no path")


def test_the_stairs_leave_the_sell_and_rankup_signs_standing(mine: MineSpec, legs: list[StairsSpec]) -> None:
    locations = build_mine(mine, Palette.load("mine_stone")).extras["locations"]
    signs = [tuple(l["pos"]) for l in locations if l["name"] in ("sell_npc_a", "rankup_npc_a")]
    alone, built = _built(mine, legs, with_legs=False), _built(mine, legs)
    assert len(signs) == 2
    assert all(alone.get(*s) not in (AIR, STONE) and built.get(*s) == alone.get(*s) for s in signs)


def test_the_committed_surface_check_ends_where_the_stairs_do(mine: MineSpec, legs: list[StairsSpec]) -> None:
    entry = next(c for c in yaml.safe_load(CHECKS.read_text(encoding="utf-8"))["checks"] if c.get("id") == "mine_a_spawn_to_surface")
    assert (entry["check"], entry["zone"], entry["world"], entry["from"]) == ("path_exists", "mine_a", "mine_a", "mine_a_spawn")
    assert tuple(int(v) for v in entry["to"].split(",")) == _goal(legs)
