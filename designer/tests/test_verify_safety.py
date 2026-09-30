import pytest

from designer.blocks import AIR
from designer.region import Bounds, Region
from designer.verify import LANDING, entity_clear, region_inside, warp_safe

# Feet on the plane's floor, well away from the hole and the lava corner.
OPEN = (10, 4, 10)


def test_clear_on_the_plane(flat_plane_with_hole: Region) -> None:
    clear = entity_clear(flat_plane_with_hole, OPEN)
    assert clear.ok and clear.detail == "clear" and clear.coords == []
    safe = warp_safe(flat_plane_with_hole, OPEN)
    assert safe.ok and safe.detail == "warp safe" and safe.coords == []


def test_entity_clear_names_the_blocked_hitbox_cells(flat_plane_with_hole: Region) -> None:
    found = entity_clear(flat_plane_with_hole, (10, 3, 10))
    assert not found.ok and found.detail == "hitbox blocked" and found.coords == [(10, 3, 10)]
    flat_plane_with_hole.set(10, 5, 10, "minecraft:stone")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox blocked" and found.coords == [(10, 5, 10)]
    flat_plane_with_hole.set(10, 5, 10, "minecraft:oak_sign")
    assert entity_clear(flat_plane_with_hole, OPEN).ok


def test_entity_clear_names_a_danger_plant_in_the_hitbox(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(10, 4, 10, "minecraft:sweet_berry_bush")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox in danger" and found.coords == [(10, 4, 10)]
    assert warp_safe(flat_plane_with_hole, OPEN) == found
    flat_plane_with_hole.set(10, 5, 10, "minecraft:stone")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox in danger" and found.coords == [(10, 4, 10)]
    flat_plane_with_hole.set(10, 4, 10, AIR)
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox blocked" and found.coords == [(10, 5, 10)]
    flat_plane_with_hole.set(10, 5, 10, "minecraft:wither_rose")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox in danger" and found.coords == [(10, 5, 10)]


def test_entity_clear_names_liquid_in_the_hitbox(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(10, 4, 10, "minecraft:water")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox in liquid" and found.coords == [(10, 4, 10)]
    assert warp_safe(flat_plane_with_hole, OPEN) == found
    flat_plane_with_hole.set(10, 5, 10, "minecraft:stone")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox in liquid" and found.coords == [(10, 4, 10)]
    flat_plane_with_hole.set(10, 5, 10, "minecraft:sweet_berry_bush")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox in danger" and found.coords == [(10, 5, 10)]
    flat_plane_with_hole.set(10, 4, 10, AIR)
    flat_plane_with_hole.set(10, 5, 10, "minecraft:flowing_water")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox in liquid" and found.coords == [(10, 5, 10)]


# Nothing holds a player up over an end portal, and stepping into one leaves
# the world, so it fails as floor, as hitbox and as a warp's neighbour.
def test_end_portal_is_never_a_place_to_stand(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(10, 3, 10, "minecraft:end_portal")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "floor is danger" and found.coords == [(10, 3, 10)]
    flat_plane_with_hole.set(10, 3, 10, "minecraft:stone")
    flat_plane_with_hole.set(10, 4, 10, "minecraft:end_portal")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox in danger" and found.coords == [(10, 4, 10)]
    flat_plane_with_hole.set(10, 4, 10, AIR)
    flat_plane_with_hole.set(11, 3, 10, "minecraft:end_portal")
    found = warp_safe(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "liquid or danger beside the hitbox" and found.coords == [(11, 3, 10)]


def test_snow_that_crowds_a_two_high_space_blocks_the_hitbox() -> None:
    column = Region.empty("snow", Bounds((0, 0, 0), (0, 3, 0)))
    column.set(0, 0, 0, "minecraft:stone")
    column.set(0, 3, 0, "minecraft:stone")
    column.set(0, 1, 0, "minecraft:snow_layer[covered_bit=false,height=4]")
    found = entity_clear(column, (0, 1, 0))
    assert not found.ok and found.detail == "hitbox blocked" and found.coords == [(0, 1, 0)]
    column.set(0, 1, 0, "minecraft:snow_layer[covered_bit=false,height=1]")
    assert entity_clear(column, (0, 1, 0)).ok


def test_fails_over_the_lava_corner(flat_plane_with_hole: Region) -> None:
    found = entity_clear(flat_plane_with_hole, (1, 4, 1))
    assert not found.ok and found.detail == "floor is danger" and found.coords == [(1, 3, 1)]
    assert warp_safe(flat_plane_with_hole, (1, 4, 1)) == found
    flat_plane_with_hole.set(10, 3, 10, "minecraft:water")
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "floor is liquid" and found.coords == [(10, 3, 10)]


def test_support_is_the_first_block_under_a_carpet(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(10, 4, 10, "minecraft:carpet")
    flat_plane_with_hole.set(10, 3, 10, "minecraft:lava")
    found = entity_clear(flat_plane_with_hole, (10, 5, 10))
    assert not found.ok and found.detail == "floor is danger" and found.coords == [(10, 3, 10)]


def test_fails_next_to_the_lava_corner(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.fill(Bounds((0, 3, 0), (2, 3, 2)), "minecraft:stone")
    flat_plane_with_hole.fill(Bounds((0, 4, 0), (2, 4, 2)), "minecraft:lava")
    assert entity_clear(flat_plane_with_hole, (3, 4, 3)).ok
    found = warp_safe(flat_plane_with_hole, (3, 4, 3))
    assert not found.ok and found.detail == "liquid or danger beside the hitbox"
    assert found.coords == [(2, 4, 2)]
    assert warp_safe(flat_plane_with_hole, (4, 4, 4)).ok


def test_floor_level_lava_in_the_ring_is_a_hazard_not_a_hole(flat_plane_with_hole: Region) -> None:
    assert entity_clear(flat_plane_with_hole, (3, 4, 3)).ok
    found = warp_safe(flat_plane_with_hole, (3, 4, 3))
    assert not found.ok and found.detail == "liquid or danger beside the hitbox"
    assert found.coords == [(2, 3, 2)]
    flat_plane_with_hole.fill(Bounds((0, 2, 0), (2, 2, 2)), "minecraft:stone")
    assert warp_safe(flat_plane_with_hole, (3, 4, 3)) == found


def test_hazard_at_head_level_trips_the_same_rule(flat_plane_with_hole: Region) -> None:
    flat_plane_with_hole.set(11, 5, 9, "minecraft:water")
    found = warp_safe(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "liquid or danger beside the hitbox"
    assert found.coords == [(11, 5, 9)]


def test_fails_over_the_hole(flat_plane_with_hole: Region) -> None:
    assert entity_clear(flat_plane_with_hole, (19, 4, 19)).ok
    found = warp_safe(flat_plane_with_hole, (19, 4, 19))
    assert not found.ok and found.detail == f"no solid within {LANDING} below" and found.coords == [(19, 3, 19)]
    flat_plane_with_hole.set(19, 1, 19, "minecraft:stone")
    assert warp_safe(flat_plane_with_hole, (19, 4, 19)).detail == f"hole deeper than {LANDING} in the floor ring"
    flat_plane_with_hole.set(19, 0, 19, "minecraft:stone")
    flat_plane_with_hole.set(19, 1, 19, AIR)
    assert warp_safe(flat_plane_with_hole, (19, 4, 19)).detail == f"no solid within {LANDING} below"


def test_fails_over_a_void_column() -> None:
    void = Region.empty("void", Bounds((0, 0, 0), (4, 63, 4)))
    assert entity_clear(void, (2, 40, 2)).ok
    found = warp_safe(void, (2, 40, 2))
    assert not found.ok and found.detail == f"no solid within {LANDING} below" and found.coords == [(2, 39, 2)]
    assert warp_safe(void, (2, 0, 2)).coords == [(2, -1, 2)]


def test_hole_in_the_floor_ring(flat_plane_with_hole: Region) -> None:
    found = warp_safe(flat_plane_with_hole, (18, 4, 19))
    assert not found.ok and found.detail == f"hole deeper than {LANDING} in the floor ring"
    assert found.coords == [(19, 3, 19), (19, 3, 20)]
    flat_plane_with_hole.fill(Bounds((19, 0, 19), (20, 0, 20)), "minecraft:stone")
    assert warp_safe(flat_plane_with_hole, (18, 4, 19)).ok
    flat_plane_with_hole.fill(Bounds((19, 0, 19), (20, 0, 20)), AIR)
    assert not warp_safe(flat_plane_with_hole, (18, 4, 19)).ok


def test_region_edge_is_unknown_not_a_hazard(flat_plane_with_hole: Region) -> None:
    assert warp_safe(flat_plane_with_hole, (39, 4, 20)).ok
    assert entity_clear(flat_plane_with_hole, (20, 7, 5)).ok
    assert warp_safe(flat_plane_with_hole, (20, 7, 5)).detail == f"no solid within {LANDING} below"


def test_warp_safe_outside_the_region_fails_instead_of_raising(flat_plane_with_hole: Region) -> None:
    found = warp_safe(flat_plane_with_hole, (100, 4, 100))
    assert not found.ok
    assert found.detail == "(100, 4, 100) is outside the fetched region (0, 0, 0)..(39, 7, 39)"
    assert found.coords == [(100, 4, 100)]


def test_entity_clear_outside_the_region_fails_instead_of_raising(flat_plane_with_hole: Region) -> None:
    found = entity_clear(flat_plane_with_hole, (100, 4, 100))
    assert not found.ok
    assert found.detail == "(100, 4, 100) is outside the fetched region (0, 0, 0)..(39, 7, 39)"
    assert found.coords == [(100, 4, 100)]


def test_a_fraction_inside_the_max_block_is_that_block(flat_plane_with_hole: Region) -> None:
    assert entity_clear(flat_plane_with_hole, (39.5, 4, 20)).ok
    assert warp_safe(flat_plane_with_hole, (39.5, 4, 20)).ok


def test_a_fraction_just_past_max_fails_the_guard(flat_plane_with_hole: Region) -> None:
    for check in (entity_clear, warp_safe):
        found = check(flat_plane_with_hole, (40.2, 4, 20))
        assert not found.ok and found.coords == [(40, 4, 20)]
        assert found.detail == "(40, 4, 20) is outside the fetched region (0, 0, 0)..(39, 7, 39)"


def test_minus_a_half_is_block_minus_one_and_fails_the_guard(flat_plane_with_hole: Region) -> None:
    for check in (entity_clear, warp_safe):
        found = check(flat_plane_with_hole, (-0.5, 4, 20))
        assert not found.ok and found.coords == [(-1, 4, 20)]
        assert found.detail == "(-1, 4, 20) is outside the fetched region (0, 0, 0)..(39, 7, 39)"


def test_region_inside_both_ways() -> None:
    outer = Bounds((0, 0, 0), (39, 7, 39))
    inner = Bounds((10, 1, 10), (20, 6, 20))
    found = region_inside(inner, outer)
    assert found.ok and found.detail == "inside" and found.coords == []
    found = region_inside(outer, inner)
    assert not found.ok and found.coords == [(0, 0, 0), (39, 7, 39)]
    assert found.detail == "corner (0, 0, 0) is outside (10, 1, 10)..(20, 6, 20)"
    found = region_inside(Bounds((10, 1, 10), (40, 6, 20)), outer)
    assert not found.ok and found.coords == [(40, 6, 20)]
    assert found.detail == "corner (40, 6, 20) is outside (0, 0, 0)..(39, 7, 39)"


# kelp and seagrass always stand in water, which DesignBridge's single-layer read never sends.
@pytest.mark.parametrize("block", ["minecraft:bubble_column", "minecraft:kelp[kelp_age=3]", "minecraft:seagrass"])
def test_entity_clear_names_a_waterlogged_or_bubbling_hitbox_liquid(flat_plane_with_hole: Region, block: str) -> None:
    flat_plane_with_hole.set(10, 4, 10, block)
    found = entity_clear(flat_plane_with_hole, OPEN)
    assert not found.ok and found.detail == "hitbox in liquid" and found.coords == [(10, 4, 10)]
