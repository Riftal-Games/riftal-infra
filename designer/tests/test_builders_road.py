import numpy as np
import pytest

from designer.builders.base import Palette
from designer.builders.road import build_road, road_profile
from designer.builders.road_spec import RoadSpec
from designer.region import Bounds2D, Heightmap, Region, heightmap_from_region
from designer.verify import path_exists


def _hm(world: str, heights: list[int], *, z: int = 0) -> Heightmap:
    bounds = Bounds2D((0, z), (len(heights) - 1, z))
    return Heightmap(world, bounds, np.array([heights], dtype=np.int16))


@pytest.fixture
def palette() -> Palette:
    return Palette.load("mine_stone")


def test_road_profile_never_steps_more_than_one() -> None:
    hm = _hm("t", [0, 0, 0, 10, 10, 10])
    centre = [(x, 0) for x in range(6)]
    profile = road_profile(hm, centre, window=1)
    assert max(abs(a - b) for a, b in zip(profile, profile[1:])) <= 1


def test_road_profile_rejects_an_empty_column() -> None:
    hm = _hm("t", [0, -1, 2])
    with pytest.raises(ValueError, match=r"no ground at \(1, 0\)"):
        road_profile(hm, [(x, 0) for x in range(3)])


def test_stairs_sit_exactly_where_the_profile_rises(palette: Palette) -> None:
    hm = _hm("road", [0, 0, 1, 1, 2, 2, 2])
    spec = RoadSpec("stepped", "road", (0, 0), (6, 0), width=1, clear_height=2)
    edits = build_road(spec, palette, hm)

    centre = spec.centre_line()
    profile = road_profile(hm, centre)
    rises = {centre[i][0] for i in range(1, len(profile)) if profile[i] > profile[i - 1]}
    assert rises == {2, 4}

    stair_fills = [op for op in edits.ops if getattr(op, "block", "").startswith(palette.block("stairs"))]
    assert {op.bounds.min[0] for op in stair_fills} == rises
    assert {op.bounds.min[1] for op in stair_fills} == {profile[2], profile[4]}


def test_flat_road_places_no_stairs(palette: Palette) -> None:
    hm = _hm("road", [3, 3, 3, 3])
    spec = RoadSpec("flat", "road", (0, 0), (3, 0), width=1, clear_height=2)
    edits = build_road(spec, palette, hm)
    assert not any(getattr(op, "block", "").startswith(palette.block("stairs")) for op in edits.ops)


def test_region_is_tagged_road_and_walkway(palette: Palette) -> None:
    hm = _hm("road", [0, 0, 0, 0])
    spec = RoadSpec("tag_me", "road", (0, 0), (3, 0), width=1, clear_height=2)
    edits = build_road(spec, palette, hm)
    assert edits.extras["regions"][0]["name"] == "tag_me"
    assert edits.extras["regions"][0]["tags"] == ["road", "walkway"]


def test_path_exists_along_the_road_crosses_the_ramps_cliff(ramp_region: Region, palette: Palette) -> None:
    hm = heightmap_from_region(ramp_region)
    spec = RoadSpec("ramp_road", "ramp", (1, 5), (26, 5), width=3, clear_height=2)

    # Direct terrain fails this crossing: a two-block cliff between x=23 and x=24 outclimbs a single step-up.
    assert not path_exists(ramp_region, (1, 1, 5), (26, 10, 5)).ok

    edits = build_road(spec, palette, hm)
    region = edits.to_region(base=ramp_region)
    centre = spec.centre_line()
    profile = road_profile(hm, centre)

    found = path_exists(region, (1, profile[0] + 1, 5), (26, profile[-1] + 1, 5))
    assert found.ok, found.detail
