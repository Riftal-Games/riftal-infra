import numpy as np
import pytest

from designer.builders.base import Palette
from designer.builders.road import EDGE_EVERY, build_road, road_profile
from designer.builders.road_spec import RoadSpec
from designer.edits import Fill, SetBlock
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


def test_embankment_fill_props_up_the_road_over_a_drop(palette: Palette) -> None:
    # A cliff at x=5: ground stays at 5 through x=4, then drops to 0. The profile is
    # slope-limited to one block per step, so it descends slower than the ground and
    # needs a wall-role fill underneath to stand on for several steps after the cliff.
    heights = [5, 5, 5, 5, 5, 0, 0, 0, 0, 0]
    hm = _hm("road", heights)
    spec = RoadSpec("cliff", "road", (0, 0), (9, 0), width=1, clear_height=2)
    edits = build_road(spec, palette, hm)

    profile = road_profile(hm, spec.centre_line())
    assert profile == [5, 5, 5, 5, 5, 4, 3, 2, 1, 0]

    wall = palette.block("wall")
    fills = {
        (op.bounds.min[0], op.bounds.min[1], op.bounds.max[1])
        for op in edits.ops
        if isinstance(op, Fill) and op.block.startswith(wall)
    }
    assert fills == {(5, 1, 3), (6, 1, 2), (7, 1, 1)}


def test_embankment_fill_absent_when_ground_matches_the_profile(palette: Palette) -> None:
    hm = _hm("road", [3, 3, 3, 3])
    spec = RoadSpec("flat", "road", (0, 0), (3, 0), width=1, clear_height=2)
    edits = build_road(spec, palette, hm)

    wall = palette.block("wall")
    assert not any(isinstance(op, Fill) and op.block.startswith(wall) for op in edits.ops)


def test_edge_posts_placed_every_edge_every_steps_when_edge_true(palette: Palette) -> None:
    hm = _hm("road", [3] * 10)
    spec = RoadSpec("edged", "road", (0, 0), (9, 0), width=3, clear_height=2, edge=True)
    edits = build_road(spec, palette, hm)

    edge_block = palette.block("road_edge")
    posts = {(op.x, op.y, op.z) for op in edits.ops if isinstance(op, SetBlock) and op.block.startswith(edge_block)}
    expected_steps = [i for i in range(10) if i % EDGE_EVERY == 0]
    assert expected_steps == [0, 4, 8]
    assert posts == {(x, 4, -1) for x in expected_steps} | {(x, 4, 1) for x in expected_steps}


def test_edge_posts_absent_when_edge_is_false(palette: Palette) -> None:
    hm = _hm("road", [3] * 10)
    spec = RoadSpec("unedged", "road", (0, 0), (9, 0), width=3, clear_height=2, edge=False)
    edits = build_road(spec, palette, hm)

    edge_block = palette.block("road_edge")
    assert not any(isinstance(op, SetBlock) and op.block.startswith(edge_block) for op in edits.ops)


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


@pytest.mark.parametrize("field", ["start", "end"])
def test_from_dict_rejects_a_fractional_coordinate(field: str) -> None:
    data = {"name": "r", "world": "road", "start": [0, 0], "end": [6, 0], field: [-0.5, 3]}
    with pytest.raises(ValueError, match="start and end must be integers"):
        RoadSpec.from_dict(data)
