"""A surface anywhere in y -64..-1 is a surface, never an empty column."""

import numpy as np
import pytest

from designer.blocks import AIR
from designer.bridge import Bridge
from designer.builders.base import Palette
from designer.builders.perimeter import PerimeterSpec, build_perimeter
from designer.builders.road import road_profile
from designer.region import Bounds, Bounds2D, Region, fetch_heightmap, heightmap_from_region
from designer.render import ascii_heightmap, summary
from designer.terrain import analyze_terrain, find_flat_site, terraform
from tests.fake_bridge import FakeBridge

WORLD = "design"
STONE = "minecraft:stone"
# Columns x 0..3 at z 0: a surface at -10, one on the floor, one at -1, and nothing.
SURFACES = [-10, -64, -1, None]


def _region() -> Region:
    region = Region.empty(WORLD, Bounds((0, -64, 0), (3, 0, 0)))
    for x, y in enumerate(SURFACES):
        if y is not None:
            region.set(x, y, 0, STONE)
    return region


def test_heightmap_from_region_reports_surfaces_below_zero_and_none_for_empty() -> None:
    hm = heightmap_from_region(_region())
    assert [hm.height(x, 0) for x in range(4)] == SURFACES
    assert [hm.top_name(x, 0) for x in range(4)] == [STONE, STONE, STONE, AIR]


@pytest.mark.parametrize("omit_top", [False, True], ids=["server_top", "no_server_top"])
def test_fetch_heightmap_tells_a_surface_at_minus_one_from_an_empty_column(fake: FakeBridge, bridge: Bridge, omit_top: bool) -> None:
    fake.omit_top = omit_top
    world = fake.worlds[WORLD]
    for x, y in enumerate(SURFACES):
        if y is not None:
            world.edits[(300 + x, y, 0)] = world.index_of(STONE)
    hm = fetch_heightmap(bridge, WORLD, Bounds2D((300, 0), (303, 0)), need_top=True)
    assert [hm.height(300 + x, 0) for x in range(4)] == SURFACES
    assert [hm.top_name(300 + x, 0) for x in range(4)] == [STONE, STONE, STONE, AIR]


def test_summary_and_ascii_count_surfaces_below_zero() -> None:
    hm = heightmap_from_region(_region())
    stats = summary(hm)
    assert (stats["columns"], stats["min"], stats["max"], stats["flat"]) == (3, -64, -1, 1 / 3)
    assert "y=-64..-1" in ascii_heightmap(hm).splitlines()[0]


def test_terrain_treats_surfaces_below_zero_as_ground() -> None:
    hm = heightmap_from_region(_region())
    stats = analyze_terrain(hm)
    assert (stats.columns, stats.min, stats.max) == (3, -64, -1)
    edits = terraform(hm, hm.bounds, mode="flatten", level=-5)
    assert edits.extras["columns"] == 3

    level = Region.empty(WORLD, Bounds((0, -64, 0), (3, 0, 3)))
    level.fill(Bounds((0, -64, 0), (3, -10, 3)), STONE)
    sites = find_flat_site(heightmap_from_region(level), 4)
    assert [(s.x, s.z, s.height) for s in sites] == [(2, 2, -10)]


def test_builders_follow_ground_below_zero_and_refuse_an_empty_column() -> None:
    hm = heightmap_from_region(_region())
    assert road_profile(hm, [(0, 0), (1, 0)], window=1) == [-10, -11]
    with pytest.raises(ValueError, match=r"no ground at \(3, 0\)"):
        road_profile(hm, [(2, 0), (3, 0)], window=1)

    spec = PerimeterSpec.from_dict({"name": "ring", "world": WORLD, "min": [0, 0], "max": [2, 2], "height": 1, "y": None})
    empty = heightmap_from_region(Region.empty(WORLD, Bounds((0, -64, 0), (2, 0, 2))))
    with pytest.raises(ValueError, match=r"no ground at \(0, 0\)"):
        build_perimeter(spec, Palette.load("mine_stone"), empty)
    floor = Region.empty(WORLD, Bounds((0, -64, 0), (2, 0, 2)))
    floor.fill(Bounds((0, -64, 0), (2, -64, 2)), STONE)
    assert {op.bounds.min[1] for op in build_perimeter(spec, Palette.load("mine_stone"), heightmap_from_region(floor)).ops} == {-63}
