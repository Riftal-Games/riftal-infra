import json

import pytest

from designer.blocks import AIR
from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.builders.stairs import StairsSpec, build_stairs
from designer.config import PROJECT_ROOT
from designer.region import Bounds, Region
from designer.verify import path_exists

STONE = "minecraft:stone"


def _json(*parts: str) -> dict:
    return json.loads(PROJECT_ROOT.joinpath(*parts).read_text(encoding="utf-8"))


@pytest.fixture
def mine() -> MineSpec:
    return MineSpec.from_dict(_json("specs", "lumber.json"))


@pytest.fixture
def stairs() -> StairsSpec:
    return StairsSpec.from_dict(_json("specs", "lumber_access.json"))


@pytest.fixture
def bounds() -> Bounds:
    return Bounds.from_json(_json("levels", "lumber.json")["bounds"])


def _ground(bounds: Bounds, top: int) -> Region:
    """Stone up to ``top`` over the whole recipe box and air above: the mine dug into land."""
    region = Region.empty("lumber", bounds)
    region.fill(Bounds(bounds.min, (bounds.max[0], top, bounds.max[2])), STONE)
    return region


def _spawn(mine: MineSpec) -> tuple[int, int, int]:
    locations = build_mine(mine, Palette.load("mine_stone")).extras["locations"]
    return tuple(next(l for l in locations if l["name"] == "lumber_spawn")["pos"])


def _built(mine: MineSpec, stairs: StairsSpec, bounds: Bounds) -> Region:
    palette = Palette.load("mine_stone")
    ground = _ground(bounds, stairs.base[1] + stairs.rise)
    return build_stairs(stairs, palette).to_region(build_mine(mine, palette).to_region(ground))


def test_the_access_starts_at_the_spawn_and_ends_inside_the_recipe_box(mine: MineSpec, stairs: StairsSpec, bounds: Bounds) -> None:
    x, y, z = _spawn(mine)
    assert stairs.world == mine.world and stairs.direction == mine.entrance.side
    assert stairs.base == (x, y - 1, z)
    top = stairs.base[1] + stairs.rise
    assert bounds.contains((x - 1, top + 2, z + stairs.rise)) and bounds.contains((x + 1, top, z + stairs.rise + 3))


def test_every_step_from_the_spawn_to_the_surface_has_a_stair_under_clear_body_space(mine: MineSpec, stairs: StairsSpec, bounds: Bounds) -> None:
    # Stairs rise a block per block of travel in half-block steps, so a player never jumps and
    # needs only the two cells over each step clear; a path search that jumps whole blocks wants a third.
    region = _built(mine, stairs, bounds)
    x, y, z = _spawn(mine)
    assert [region.get(x, y + dy, z) for dy in (0, 1)] == [AIR, AIR]
    for i in range(1, stairs.rise + 1):
        for dx in range(-(stairs.width // 2), stairs.width - stairs.width // 2):
            floor = region.get(x + dx, y - 1 + i, z + i)
            assert floor.startswith("minecraft:stone_brick_stairs"), (i, dx, floor)
            assert [region.get(x + dx, y + i + dy, z + i) for dy in (0, 1)] == [AIR, AIR], (i, dx)


def test_the_lane_from_the_spawn_reaches_the_logs(mine: MineSpec, stairs: StairsSpec, bounds: Bounds) -> None:
    x, y, z = _spawn(mine)
    entrance = mine.geometry().entrance
    found = path_exists(_built(mine, stairs, bounds), (x, y, z), (x, entrance.min[1], entrance.max[2]))
    assert found.ok, found.detail


def test_the_mine_alone_leaves_the_spawn_sealed_under_the_ground(mine: MineSpec, stairs: StairsSpec, bounds: Bounds) -> None:
    x, y, z = _spawn(mine)
    surface = stairs.base[1] + stairs.rise
    region = build_mine(mine, Palette.load("mine_stone")).to_region(_ground(bounds, surface))
    sealed = path_exists(region, (x, y, z), (x, surface + 1, z + stairs.rise + 3))
    assert (sealed.ok, sealed.detail) == (False, "no path")
