import numpy as np
import pytest

from designer.blocks import AIR
from designer.region import Bounds, Region
from designer.verify import SPRINT_SPEED, WALK_SPEED, WEB_COST, _snap, path_exists, stand_mask, travel_time

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


def test_stand_mask_on_a_view_recomputes_after_a_parent_edit(flat_plane_with_hole: Region) -> None:
    view = flat_plane_with_hole.sub(Bounds((0, 0, 0), (9, 7, 9)))
    assert stand_mask(view).shape == (8, 10, 10) and stand_mask(view)[4, 3, 3]
    flat_plane_with_hole.set(3, 3, 3, AIR)
    assert not stand_mask(view)[4, 3, 3]


def test_web_mask_is_cached_until_an_edit_and_a_view_recomputes(flat_plane_with_hole: Region) -> None:
    mask = flat_plane_with_hole.web_mask()
    assert mask.shape == (8, 40, 40) and not mask.any()
    assert flat_plane_with_hole.web_mask() is mask
    view = flat_plane_with_hole.sub(Bounds((0, 0, 0), (9, 7, 9)))
    assert not view.web_mask()[4, 3, 3]
    flat_plane_with_hole.set(3, 5, 3, "minecraft:web")
    after = flat_plane_with_hole.web_mask()
    assert after is not mask and after[4, 3, 3] and after[5, 3, 3] and not after[6, 3, 3]
    assert view.web_mask()[4, 3, 3]


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
    assert up.coords and all(x <= 23 for x, _, _ in up.coords)
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


def test_snap_floors_negative_coordinates() -> None:
    region = Region.empty("negative", Bounds((-10, 0, -10), (-1, 7, -1)))
    region.fill(Bounds((-10, 3, -10), (-1, 3, -1)), "minecraft:stone")
    mask = stand_mask(region)
    assert _snap(mask, region.bounds, (-0.5, 4.0, -0.5), 0) == (4, 9, 9)
    assert _snap(mask, region.bounds, (-9.5, 4.9, -1.2), 0) == (4, 8, 0)


def test_step_up_needs_head_room_over_the_jump(ramp_with_ceiling: Region) -> None:
    found = path_exists(ramp_with_ceiling, (1, 1, 5), (22, 8, 5))
    assert not found.ok and found.detail == "no path"
    assert found.coords and all(x <= 2 and y == 1 for x, y, _ in found.coords)


def test_drop_needs_head_room_at_take_off() -> None:
    # A lintel over the lower cell: walking off the ledge puts the head into
    # it, and the jump back up has nowhere for the head, so both ways are shut.
    region = Region.empty("lintel", Bounds((0, 0, 0), (2, 5, 0)))
    for pos in ((0, 0, 0), (0, 1, 0), (1, 0, 0), (2, 0, 0), (1, 3, 0)):
        region.set(*pos, "minecraft:stone")
    assert path_exists(region, (0, 2, 0), (1, 1, 0)).detail == "no path"
    assert path_exists(region, (1, 1, 0), (0, 2, 0)).detail == "no path"


TALL_FLOORS = ["minecraft:oak_fence", "minecraft:cobblestone_wall", "minecraft:fence_gate"]


def _fenced_lane(tall: str) -> Region:
    region = Region.empty("fenced lane", Bounds((0, 0, 0), (9, 6, 0)))
    region.fill(Bounds((0, 0, 0), (9, 0, 0)), "minecraft:stone")
    region.set(5, 1, 0, tall)
    return region


@pytest.mark.parametrize("tall", TALL_FLOORS)
def test_no_step_up_onto_a_fence_wall_or_closed_gate(tall: str) -> None:
    region = _fenced_lane(tall)
    assert stand_mask(region)[2, 0, 5]
    found = path_exists(region, (0, 1, 0), (9, 1, 0))
    assert not found.ok and found.detail == "no path"
    assert not travel_time(region, (0, 1, 0), (9, 1, 0)).ok
    assert path_exists(region, (5, 2, 0), (9, 1, 0)).ok


@pytest.mark.parametrize("tall", TALL_FLOORS)
def test_level_step_onto_a_flush_tall_floor_walks(tall: str) -> None:
    region = _fenced_lane(tall)
    region.fill(Bounds((0, 1, 0), (4, 1, 0)), "minecraft:stone")
    found = path_exists(region, (0, 2, 0), (5, 2, 0))
    assert found.ok and found.length == pytest.approx(5)


def _fence_stair(ceiling: bool) -> Region:
    region = _fenced_lane("minecraft:oak_fence")
    region.set(6, 1, 0, "minecraft:oak_fence")
    region.set(6, 2, 0, "minecraft:oak_fence")
    if ceiling:
        region.set(5, 5, 0, "minecraft:stone")
    return region


def test_step_up_from_one_tall_floor_to_another_climbs() -> None:
    found = path_exists(_fence_stair(False), (5, 2, 0), (6, 3, 0))
    assert found.ok and found.path == [(5, 2, 0), (6, 3, 0)]


def test_step_up_from_a_tall_floor_needs_the_third_cell_for_the_head() -> None:
    region = _fence_stair(True)
    assert stand_mask(region)[2, 0, 5]
    assert path_exists(region, (5, 2, 0), (6, 3, 0), snap_radius=0).detail == "no path"


def _lane(web_at:tuple[int, int, int] | None) -> Region:
    region = Region.empty("lane", Bounds((0, 0, 0), (9, 3, 0)))
    region.fill(Bounds((0, 0, 0), (9, 0, 0)), "minecraft:stone")
    if web_at is not None:
        region.set(*web_at, "minecraft:web")
    return region


@pytest.mark.parametrize("web_y", [1, 2])
def test_web_at_feet_or_head_costs_its_slowdown(web_y: int) -> None:
    found = path_exists(_lane((5, web_y, 0)), (0, 1, 0), (9, 1, 0))
    assert found.ok and len(found.path) == 10
    assert found.length == pytest.approx(9 - 1 + WEB_COST)
    assert travel_time(_lane((5, web_y, 0)), (0, 1, 0), (9, 1, 0)).seconds == pytest.approx((8 + WEB_COST) / WALK_SPEED)


def test_cobweb_costs_the_same_as_web() -> None:
    region = _lane(None)
    region.set(5, 1, 0, "minecraft:cobweb")
    assert path_exists(region, (0, 1, 0), (9, 1, 0)).length == pytest.approx(8 + WEB_COST)


def test_path_walks_round_a_web_when_the_detour_is_cheaper() -> None:
    region = Region.empty("two lanes", Bounds((0, 0, 0), (9, 3, 1)))
    region.fill(Bounds((0, 0, 0), (9, 0, 1)), "minecraft:stone")
    region.set(5, 1, 0, "minecraft:web")
    found = path_exists(region, (0, 1, 0), (9, 1, 0))
    assert found.ok and (5, 1, 0) not in found.path
    assert found.length == pytest.approx(9 + 2)


def test_water_floor_is_not_standable(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(5, 3, 5, "minecraft:water")
    assert not stand_mask(flat_plane_with_hole)[4, 5, 5]


def test_lava_at_the_feet_is_not_standable(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(6, 4, 6, "minecraft:lava")
    assert not stand_mask(flat_plane_with_hole)[4, 6, 6]


UNKNOWN = "a block the core does not map (minecraft:info_update)"


def test_an_unmapped_floor_is_standable_only_when_asked(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(5, 3, 5, "minecraft:info_update")
    mask = stand_mask(flat_plane_with_hole)
    assert not mask[4, 5, 5] and mask[4, 5, 6]
    assert flat_plane_with_hole.stand_mask(unmapped_floor=True)[4, 5, 5]
    assert stand_mask(flat_plane_with_hole) is mask
    assert flat_plane_with_hole.unmapped().sum() == 1


def test_path_walks_round_an_unmapped_floor(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(10, 3, 20, "minecraft:info_update")
    found = path_exists(flat_plane_with_hole, A, B)
    assert found.ok and (10, 4, 20) not in found.path


def test_a_route_only_over_an_unmapped_floor_fails_and_names_it(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.fill(Bounds((19, 3, 0), (20, 3, 39)), AIR)
    flat_plane_with_hole.fill(Bounds((19, 3, 20), (20, 3, 20)), "minecraft:info_update")
    found = path_exists(flat_plane_with_hole, A, B)
    assert (found.ok, found.detail) == (False, f"path only over {UNKNOWN}")
    assert found.coords == [(19, 3, 20), (20, 3, 20)]
    assert found.path[0] == A and found.path[-1] == B and _adjacent(found.path)
    timed = travel_time(flat_plane_with_hole, A, B)
    assert (timed.ok, timed.detail, timed.coords) == (False, found.detail, found.coords)


def test_an_end_on_an_unmapped_floor_is_named(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.fill(Bounds((35, 3, 18), (39, 3, 22)), "minecraft:info_update")
    found = path_exists(flat_plane_with_hole, A, B)
    assert (found.ok, found.detail) == (False, f"path only over {UNKNOWN}")
    assert found.coords[-1] == (37, 3, 20)
