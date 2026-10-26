import json

import pytest

from designer.blocks import AIR
from designer.builders.base import DIRS, Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.builders.stairs import StairsSpec, build_stairs
from designer.config import PROJECT_ROOT
from designer.level import pregen_bounds
from designer.region import Bounds, Region
from designer.verify import path_exists

STONE = "minecraft:stone"
LEGS = ("lumber_access_south.json", "lumber_access_east.json")


def _json(*parts: str) -> dict:
    return json.loads(PROJECT_ROOT.joinpath(*parts).read_text(encoding="utf-8"))


@pytest.fixture
def mine() -> MineSpec:
    return MineSpec.from_dict(_json("specs", "lumber.json"))


@pytest.fixture
def legs() -> list[StairsSpec]:
    return [StairsSpec.from_dict(_json("specs", name)) for name in LEGS]


def _top(leg: StairsSpec) -> tuple[int, int, int]:
    """The last tread of ``leg``: the cell under the feet of someone at the top of it."""
    dx, dz = DIRS[leg.direction]
    return leg.base[0] + dx * leg.rise, leg.base[1] + leg.rise, leg.base[2] + dz * leg.rise


def _spawn(mine: MineSpec) -> tuple[int, int, int]:
    locations = build_mine(mine, Palette.load("mine_stone")).extras["locations"]
    return tuple(next(l for l in locations if l["name"] == "lumber_spawn")["pos"])


def _built(mine: MineSpec, legs: list[StairsSpec], surface: int, with_legs: bool = True) -> Region:
    """The mine and its stairs dug into stone that reaches ``surface``, over the chunks ``pregen`` populates."""
    palette = Palette.load("mine_stone")
    recipe = Bounds.from_json(_json("levels", "lumber.json")["bounds"])
    area = pregen_bounds(recipe)
    region = Region.empty("lumber", Bounds((area.min[0], recipe.min[1], area.min[1]), (area.max[0], surface + 3, area.max[1])))
    region.fill(Bounds(region.bounds.min, (region.bounds.max[0], surface, region.bounds.max[2])), STONE)
    region = build_mine(mine, palette).to_region(region)
    for leg in legs if with_legs else ():
        region = build_stairs(leg, palette).to_region(region)
    return region


def test_the_legs_chain_from_the_spawn_and_stay_in_the_populated_chunks(mine: MineSpec, legs: list[StairsSpec]) -> None:
    x, y, z = _spawn(mine)
    first, second = legs
    assert first.world == second.world == mine.world and first.direction == mine.entrance.side
    assert first.base == (x, y - 1, z)
    assert second.base == _top(first)
    area = pregen_bounds(Bounds.from_json(_json("levels", "lumber.json")["bounds"]))
    for leg in legs:
        for tread in (leg.base, _top(leg)):
            for lateral in (-(leg.width // 2), leg.width - 1 - leg.width // 2):
                dx, dz = DIRS[leg.direction]
                assert area.contains((tread[0] + abs(dz) * lateral, tread[2] + abs(dx) * lateral))


def test_every_step_from_the_spawn_to_the_surface_has_a_stair_under_clear_body_space(mine: MineSpec, legs: list[StairsSpec]) -> None:
    # Stairs rise a block per block of travel in half-block steps, so a person never jumps and
    # needs only the two cells over each step clear; a path search that jumps whole blocks wants a third.
    surface = _top(legs[-1])[1]
    region = _built(mine, legs, surface)
    x, y, z = _spawn(mine)
    assert [region.get(x, y + dy, z) for dy in (0, 1)] == [AIR, AIR]
    wall = Palette.load("mine_stone").block("wall")
    for leg in legs:
        dx, dz = DIRS[leg.direction]
        for i in range(1, leg.rise + 1):
            for lateral in range(-(leg.width // 2), leg.width - leg.width // 2):
                # The second leg turns east off the first leg's last tread and its first row's support and walls
                # stand in the first leg's last two rows on that side.
                if leg is legs[0] and i >= leg.rise - 1 and lateral > 0:
                    continue
                cx, cy, cz = leg.base[0] + dx * i + abs(dz) * lateral, leg.base[1] + i, leg.base[2] + dz * i + abs(dx) * lateral
                floor = region.get(cx, cy, cz)
                assert floor.startswith("minecraft:stone_brick_stairs") or floor == wall, (leg.direction, i, lateral, floor)
                assert [region.get(cx, cy + up, cz) for up in (1, 2)] == [AIR, AIR], (leg.direction, i, lateral)


def test_the_lane_from_the_spawn_reaches_the_logs(mine: MineSpec, legs: list[StairsSpec]) -> None:
    x, y, z = _spawn(mine)
    entrance = mine.geometry().entrance
    found = path_exists(_built(mine, legs, _top(legs[-1])[1]), (x, y, z), (x, entrance.min[1], entrance.max[2]))
    assert found.ok, found.detail


def test_the_mine_alone_leaves_the_spawn_sealed_under_the_ground(mine: MineSpec, legs: list[StairsSpec]) -> None:
    x, y, z = _spawn(mine)
    ex, ey, ez = _top(legs[-1])
    sealed = path_exists(_built(mine, legs, ey, with_legs=False), (x, y, z), (ex + 2, ey + 1, ez))
    assert (sealed.ok, sealed.detail) == (False, "no path")
