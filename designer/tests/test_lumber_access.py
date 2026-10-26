import json

import pytest

from designer.blocks import AIR
from designer.builders.base import DIRS, Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.builders.stairs import StairsSpec, build_stairs
from designer.config import PROJECT_ROOT
from designer.level import load_recipe, pregen_bounds
from designer.region import Bounds, Region
from designer.verify import path_exists

STONE = "minecraft:stone"
# The top block of seed 23's plateau east of the stairs' last tread, read from the built level's heightmap.
# A tread one lower tops out 1.5 blocks under that grass, more than a jump clears.
EXIT_GROUND_Y = 64
# Stepping up a row leaves the body's edge in the column behind, so that column needs a third cell clear.
CLEAR_ABOVE = (1, 2, 3)


def _json(*parts: str) -> dict:
    return json.loads(PROJECT_ROOT.joinpath(*parts).read_text(encoding="utf-8"))


@pytest.fixture
def mine() -> MineSpec:
    return MineSpec.from_dict(_json("specs", "lumber.json"))


@pytest.fixture
def legs() -> list[StairsSpec]:
    steps = [step for step in load_recipe("lumber").steps if step.build == "stairs"]
    return [StairsSpec.from_dict(json.loads(PROJECT_ROOT.joinpath(step.spec).read_text(encoding="utf-8"))) for step in steps]


def _top(leg: StairsSpec) -> tuple[int, int, int]:
    """The last tread of ``leg``: the cell under the feet of someone at the top of it."""
    dx, dz = DIRS[leg.direction]
    return leg.base[0] + dx * leg.rise, leg.base[1] + leg.rise, leg.base[2] + dz * leg.rise


def _spawn(mine: MineSpec) -> tuple[int, int, int]:
    locations = build_mine(mine, Palette.load("mine_stone")).extras["locations"]
    return tuple(next(l for l in locations if l["name"] == "lumber_spawn")["pos"])


def _built(mine: MineSpec, legs: list[StairsSpec], with_legs: bool = True) -> Region:
    """The mine and its stairs dug into stone that reaches the exit's ground, over the chunks ``pregen`` populates."""
    palette = Palette.load("mine_stone")
    recipe = Bounds.from_json(_json("levels", "lumber.json")["bounds"])
    area = pregen_bounds(recipe)
    region = Region.empty("lumber", Bounds((area.min[0], recipe.min[1], area.min[1]), (area.max[0], EXIT_GROUND_Y + 3, area.max[1])))
    region.fill(Bounds(region.bounds.min, (region.bounds.max[0], EXIT_GROUND_Y, region.bounds.max[2])), STONE)
    region = build_mine(mine, palette).to_region(region)
    for leg in legs if with_legs else ():
        region = build_stairs(leg, palette).to_region(region)
    return region


def _goal(legs: list[StairsSpec]) -> tuple[int, int, int]:
    """Standing room on the ground two cells past the last tread."""
    dx, dz = DIRS[legs[-1].direction]
    x, _, z = _top(legs[-1])
    return x + 2 * dx, EXIT_GROUND_Y + 1, z + 2 * dz


def test_the_legs_chain_from_the_spawn_and_stay_in_the_populated_chunks(mine: MineSpec, legs: list[StairsSpec]) -> None:
    x, y, z = _spawn(mine)
    assert legs and all(leg.world == mine.world for leg in legs)
    assert legs[0].direction == mine.entrance.side and legs[0].base == (x, y - 1, z)
    for before, after in zip(legs, legs[1:]):
        assert after.base == _top(before)
    area = pregen_bounds(Bounds.from_json(_json("levels", "lumber.json")["bounds"]))
    for leg in legs:
        for tread in (leg.base, _top(leg)):
            for lateral in (-(leg.width // 2), leg.width - 1 - leg.width // 2):
                dx, dz = DIRS[leg.direction]
                assert area.contains((tread[0] + abs(dz) * lateral, tread[2] + abs(dx) * lateral))


def test_the_last_tread_is_flush_with_seed_23s_ground_at_the_exit(legs: list[StairsSpec]) -> None:
    recipe = load_recipe("lumber")
    assert recipe.seed == 23
    assert _top(legs[-1])[1] == EXIT_GROUND_Y


def test_every_step_from_the_spawn_to_the_surface_has_a_stair_under_clear_body_space(mine: MineSpec, legs: list[StairsSpec]) -> None:
    region = _built(mine, legs)
    x, y, z = _spawn(mine)
    # The first step off the spawn leaves the lane's end, so its third cell up needs clearing too.
    assert [region.get(x, y + dy, z) for dy in (0, 1, 2)] == [AIR] * 3
    wall = Palette.load("mine_stone").block("wall")
    for leg in legs:
        dx, dz = DIRS[leg.direction]
        for i in range(1, leg.rise + 1):
            for lateral in range(-(leg.width // 2), leg.width - leg.width // 2):
                # The next leg turns off this leg's last tread, and its first row's support and walls
                # stand in this leg's last two rows on that side.
                if leg is not legs[-1] and i >= leg.rise - 1 and lateral > 0:
                    continue
                cx, cy, cz = leg.base[0] + dx * i + abs(dz) * lateral, leg.base[1] + i, leg.base[2] + dz * i + abs(dx) * lateral
                floor = region.get(cx, cy, cz)
                assert floor.startswith("minecraft:stone_brick_stairs") or floor == wall, (leg.direction, i, lateral, floor)
                assert [region.get(cx, cy + up, cz) for up in CLEAR_ABOVE] == [AIR] * 3, (leg.direction, i, lateral)


def test_the_stairs_carry_a_walker_from_the_spawn_onto_the_ground(mine: MineSpec, legs: list[StairsSpec]) -> None:
    found = path_exists(_built(mine, legs), _spawn(mine), _goal(legs))
    assert found.ok, found.detail


def test_the_lane_from_the_spawn_reaches_the_logs(mine: MineSpec, legs: list[StairsSpec]) -> None:
    x, y, z = _spawn(mine)
    entrance = mine.geometry().entrance
    found = path_exists(_built(mine, legs), (x, y, z), (x, entrance.min[1], entrance.max[2]))
    assert found.ok, found.detail


def test_the_mine_alone_leaves_the_spawn_sealed_under_the_ground(mine: MineSpec, legs: list[StairsSpec]) -> None:
    sealed = path_exists(_built(mine, legs, with_legs=False), _spawn(mine), _goal(legs))
    assert (sealed.ok, sealed.detail) == (False, "no path")
