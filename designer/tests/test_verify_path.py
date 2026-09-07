import numpy as np
import pytest

from designer.blocks import AIR
from designer.region import Bounds, Region
from designer.verify import SPRINT_SPEED, WALK_SPEED, path_exists, stand_mask, travel_time

# Feet on the plane's floor, either side of the hole along z=20.
A, B = (2, 4, 20), (37, 4, 20)


def _adjacent(path: list[tuple[int, int, int]]) -> bool:
    return all(abs(p[0] - q[0]) + abs(p[2] - q[2]) == 1 for p, q in zip(path, path[1:]))


def test_stand_mask_shape_edges_and_cache(flat_plane_with_hole: Region) -> None:
    mask = stand_mask(flat_plane_with_hole)
    assert mask.shape == (8, 40, 40) and mask.dtype == bool
    assert not mask[0].any() and not mask[-1].any()
    assert mask[4].sum() == 40 * 40 - 4 - 9
    assert not mask[4, 19, 19] and not mask[4, 1, 1] and mask[4, 3, 3]
    assert stand_mask(flat_plane_with_hole) is mask
    flat_plane_with_hole.set(3, 3, 3, "minecraft:lava")
    assert not stand_mask(flat_plane_with_hole)[4, 3, 3]


def test_path_across_plane_is_near_manhattan_and_bounded(flat_plane_with_hole: Region) -> None:
    found = path_exists(flat_plane_with_hole, A, B)
    assert found.ok and found.detail == "path found"
    assert found.path[0] == A and found.path[-1] == B and _adjacent(found.path)
    assert 35 <= found.length <= 35 + 4
    assert found.length == len(found.path) - 1
    assert 0 < found.explored <= 4 * 40, found.explored
    assert all(p[1] == 4 for p in found.path)


def test_widened_hole_gives_no_path_with_hints(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.fill(Bounds((19, 3, 0), (20, 3, 39)), AIR)
    found = path_exists(flat_plane_with_hole, A, B)
    assert not found.ok and found.detail == "no path" and found.path == []
    assert 1 <= len(found.coords) <= 5
    assert all(x == 18 and y == 4 for x, y, _ in found.coords)


def test_corridor_excluding_the_detour_gives_no_path(flat_plane_with_hole: Region) -> None:
    corridor = Bounds((0, 0, 19), (39, 7, 20))
    found = path_exists(flat_plane_with_hole, A, B, corridor=corridor)
    assert not found.ok and found.detail == "no path"
    assert found.data["corridor"] == corridor.to_json()
    assert path_exists(flat_plane_with_hole, A, B, corridor=corridor.expand(1, "z")).ok


def test_node_cap_trips(flat_plane_with_hole: Region) -> None:
    found = path_exists(flat_plane_with_hole, A, B, max_nodes=10)
    assert not found.ok and found.detail == "node cap reached"
    assert found.explored == 10 and found.coords


def test_ramp_step_up_climbs(ramp_region: Region) -> None:
    found = path_exists(ramp_region, (1, 1, 5), (22, 8, 5))
    assert found.ok and found.path[0] == (1, 1, 5) and found.path[-1] == (22, 8, 5)
    ys = [p[1] for p in found.path]
    assert ys == sorted(ys) and max(np.diff(ys)) == 1
    assert found.length == pytest.approx(21 + 7 * 0.5)


def test_cliff_blocks_unless_dropping_down_it(ramp_region: Region) -> None:
    up = path_exists(ramp_region, (1, 1, 5), (26, 10, 5))
    assert not up.ok and up.detail == "no path"
    assert all(x <= 23 for x, _, _ in up.coords)
    down = path_exists(ramp_region, (26, 10, 5), (22, 8, 5))
    assert not down.ok and down.detail == "no path"
    down = path_exists(ramp_region, (26, 10, 5), (22, 8, 5), max_drop=2)
    assert down.ok and down.length == pytest.approx(4 + 2 * 0.25)


def test_travel_time_is_blocks_over_speed(flat_plane_with_hole: Region) -> None:
    walk = travel_time(flat_plane_with_hole, A, B)
    assert walk.ok and walk.blocks == path_exists(flat_plane_with_hole, A, B).length
    assert walk.seconds == pytest.approx(walk.blocks / 4.317, rel=1e-6)
    assert walk.seconds == pytest.approx(walk.blocks / WALK_SPEED)
    assert walk.path[-1] == B
    sprint = travel_time(flat_plane_with_hole, A, B, speed=SPRINT_SPEED)
    assert sprint.seconds == pytest.approx(walk.blocks / 5.612)


def test_start_or_goal_inside_rock_fails_with_detail(ramp_region: Region) -> None:
    found = path_exists(ramp_region, (20, 2, 5), (1, 1, 5))
    assert not found.ok and found.detail == "start not standable" and found.coords == [(20, 2, 5)]
    found = path_exists(ramp_region, (1, 1, 5), (20, 2, 5))
    assert not found.ok and found.detail == "goal not standable" and found.coords == [(20, 2, 5)]
    capped = travel_time(ramp_region, (20, 2, 5), (1, 1, 5))
    assert not capped.ok and capped.detail == "start not standable"


def test_endpoints_snap_to_the_nearest_standable_cell(flat_plane_with_hole: Region) -> None:
    found = path_exists(flat_plane_with_hole, (2, 6, 20), (37, 3, 20))
    assert found.ok and found.path[0] == A and found.path[-1] == B
    assert found.data["start"] == A and found.data["goal"] == B


def test_step_up_needs_head_room_over_the_jump(ramp_with_ceiling: Region) -> None:
    found = path_exists(ramp_with_ceiling, (1, 1, 5), (22, 8, 5))
    assert not found.ok and found.detail == "no path"
    assert all(x <= 2 and y == 1 for x, y, _ in found.coords)


def test_drop_needs_head_room_at_take_off() -> None:
    # A lintel over the lower cell: walking off the ledge puts the head into
    # it, and the jump back up has nowhere for the head, so both ways are shut.
    region = Region.empty("lintel", Bounds((0, 0, 0), (2, 5, 0)))
    for pos in ((0, 0, 0), (0, 1, 0), (1, 0, 0), (2, 0, 0), (1, 3, 0)):
        region.set(*pos, "minecraft:stone")
    assert path_exists(region, (0, 2, 0), (1, 1, 0)).detail == "no path"
    assert path_exists(region, (1, 1, 0), (0, 2, 0)).detail == "no path"


def test_water_floor_is_not_standable(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(5, 3, 5, "minecraft:water")
    assert not stand_mask(flat_plane_with_hole)[4, 5, 5]


def test_lava_at_the_feet_is_not_standable(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(6, 4, 6, "minecraft:lava")
    assert not stand_mask(flat_plane_with_hole)[4, 6, 6]
