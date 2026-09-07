import numpy as np
import pytest

from designer.blocks import AIR, BlockClass
from designer.region import Bounds, Bounds2D, Region

WORLD = "mine_a"


def test_bounds_are_inclusive() -> None:
    assert Bounds((0, 0, 0), (0, 0, 0)).size == (1, 1, 1)
    box = Bounds((-3, 40, 9), (7, 44, 15))
    assert box.size == (11, 5, 7)
    assert box.shape == (5, 7, 11)
    assert box.volume == 385
    assert Bounds.from_size((-3, 40, 9), (11, 5, 7)) == box
    assert box.contains((7, 44, 15)) and not box.contains((8, 44, 15))


def test_bounds_normalise_any_corner_order() -> None:
    assert Bounds((7, 40, 15), (-3, 44, 9)) == Bounds((-3, 40, 9), (7, 44, 15))
    assert Bounds2D((5, -5), (-5, 5)) == Bounds2D((-5, -5), (5, 5))
    with pytest.raises(ValueError):
        Bounds((0, 0), (1, 1))


def test_from_center_even_size_puts_center_in_the_upper_middle() -> None:
    assert Bounds.from_center((10, 10, 10), (5, 5, 5)) == Bounds((8, 8, 8), (12, 12, 12))
    assert Bounds.from_center((10, 10, 10), (4, 4, 4)) == Bounds((8, 8, 8), (11, 11, 11))
    with pytest.raises(ValueError):
        Bounds.from_size((0, 0, 0), (1, 0, 1))


@pytest.mark.parametrize("edge", [1, 128, 129, 300])
def test_tiles_cover_each_cell_exactly_once(edge: int) -> None:
    box = Bounds.from_size((-70, 3, 5), (edge, edge, edge))
    tiles = box.tiles(128)
    cover = np.zeros(box.shape, dtype=np.uint8)
    for tile in tiles:
        assert max(tile.size) <= 128
        assert box.intersect(tile) == tile
        cover[box.slices(tile)] += 1
    assert sum(t.volume for t in tiles) == box.volume
    assert (cover == 1).all()
    assert len(tiles) == (-(-edge // 128)) ** 3


def test_bounds2d_tiles_and_json() -> None:
    flat = Bounds2D((0, 0), (299, 129))
    assert len(flat.tiles(128)) == 6
    assert sum(t.volume for t in flat.tiles(128)) == flat.volume
    assert Bounds2D.from_json(flat.to_json()) == flat
    with pytest.raises(ValueError):
        flat.tiles(0)


def test_intersect_and_union() -> None:
    a, b = Bounds((0, 0, 0), (9, 9, 9)), Bounds((5, -5, 5), (20, 4, 20))
    assert a.intersect(b) == Bounds((5, 0, 5), (9, 4, 9))
    assert a.intersect(Bounds((10, 0, 0), (12, 9, 9))) is None
    assert a.union(b) == Bounds((0, -5, 0), (20, 9, 20))


def test_expand_per_axis() -> None:
    box = Bounds((0, 0, 0), (1, 1, 1))
    assert box.expand(2, "y") == Bounds((0, -2, 0), (1, 3, 1))
    assert box.expand(1, "xz") == Bounds((-1, 0, -1), (2, 1, 2))
    assert box.expand(1) == Bounds((-1, -1, -1), (2, 2, 2))
    with pytest.raises(ValueError):
        box.expand(1, "w")


def test_local_is_yzx_from_the_min_corner() -> None:
    box = Bounds((-3, 40, 9), (7, 44, 15))
    assert box.local((-3, 40, 9)) == (0, 0, 0)
    assert box.local((7, 44, 15)) == (4, 6, 10)
    assert box.local((0, 41, 10)) == (1, 1, 3)
    with pytest.raises(ValueError):
        box.local((8, 40, 9))


def test_json_round_trip_is_the_wire_shape() -> None:
    box = Bounds((-3, 40, 9), (7, 44, 15))
    assert box.to_json() == {"min": [-3, 40, 9], "max": [7, 44, 15]}
    assert Bounds.from_json({"min": [7, 44, 15], "max": [-3, 40, 9]}) == box


def test_get_set_grow_the_palette_and_refresh_classes() -> None:
    region = Region.empty(WORLD, Bounds((0, 0, 0), (2, 2, 2)))
    assert region.get(1, 1, 1) == AIR and region.palette == [AIR]
    assert not region.classes().any()
    region.set(1, 1, 1, "minecraft:stone")
    assert region.palette == [AIR, "minecraft:stone"]
    assert region.get(1, 1, 1) == "minecraft:stone"
    assert region.classes()[1, 1, 1] == BlockClass.SOLID
    region.set(1, 1, 1, "minecraft:water")
    assert region.classes()[1, 1, 1] == BlockClass.LIQUID
    region.set(2, 0, 1, "minecraft:stone")
    assert region.palette == [AIR, "minecraft:stone", "minecraft:water"]
    assert region.counts() == {AIR: 25, "minecraft:stone": 1, "minecraft:water": 1}
    assert region.index_of("minecraft:water", add=False) == 2
    with pytest.raises(KeyError):
        region.index_of("minecraft:lava", add=False)
    with pytest.raises(ValueError):
        region.get(3, 0, 0)


def test_empty_with_fill_and_bad_construction() -> None:
    filled = Region.empty(WORLD, Bounds((0, 0, 0), (1, 1, 1)), fill="minecraft:stone")
    assert filled.counts() == {"minecraft:stone": 8}
    with pytest.raises(ValueError):
        Region(WORLD, Bounds((0, 0, 0), (1, 1, 1)), np.zeros((2, 2, 2), dtype=np.int16), ["minecraft:stone"])
    with pytest.raises(ValueError):
        Region(WORLD, Bounds((0, 0, 0), (1, 1, 1)), np.zeros((1, 2, 2), dtype=np.int16), [AIR])


def test_sub_is_a_view_over_the_intersection() -> None:
    parent = Region.empty(WORLD, Bounds((0, 0, 0), (9, 9, 9)))
    assert parent.classes().shape == (10, 10, 10)
    view = parent.sub(Bounds((5, 5, 5), (20, 20, 20)))
    assert view.bounds == Bounds((5, 5, 5), (9, 9, 9))
    assert np.shares_memory(view.blocks, parent.blocks)
    view.set(7, 6, 8, "minecraft:lava")
    assert parent.get(7, 6, 8) == "minecraft:lava"
    assert parent.palette is view.palette
    assert parent.classes()[6, 8, 7] == BlockClass.DANGER
    assert view.classes()[1, 3, 2] == BlockClass.DANGER
    with pytest.raises(ValueError):
        parent.sub(Bounds((10, 0, 0), (12, 2, 2)))


def _random_region(rng: np.random.Generator, bounds: Bounds, names: int) -> Region:
    palette = [AIR, *(f"minecraft:block_{i}" for i in range(1, names))]
    return Region(WORLD, bounds, rng.integers(0, names, size=bounds.shape, dtype=np.int16), palette)


def _names(region: Region) -> np.ndarray:
    return np.array(region.palette)[region.blocks]


def test_rle_round_trip_keeps_world_bounds_and_blocks() -> None:
    region = _random_region(np.random.default_rng(3), Bounds((-3, 40, 9), (7, 44, 15)), 4)
    payload = region.to_rle()
    assert payload["world"] == WORLD and payload["min"] == [-3, 40, 9] and payload["max"] == [7, 44, 15]
    back = Region.from_rle(WORLD, payload)
    assert (back.world, back.bounds, back.palette) == (WORLD, region.bounds, region.palette)
    np.testing.assert_array_equal(back.blocks, region.blocks)


def _shuffled_palette(tile: Region, rng: np.random.Generator) -> Region:
    perm = [0, *rng.permutation(np.arange(1, len(tile.palette))).tolist()]
    lut = np.empty(len(perm), dtype=np.int16)
    lut[perm] = np.arange(len(perm))
    return Region(tile.world, tile.bounds, lut[tile.blocks], [tile.palette[i] for i in perm])


def test_merge_of_tiles_reproduces_the_region() -> None:
    rng = np.random.default_rng(11)
    original = _random_region(rng, Bounds.from_size((-100, 30, 50), (150, 20, 130)), 6)
    tiles = [_shuffled_palette(original.sub(t), rng) for t in original.bounds.tiles(64)]
    rng.shuffle(tiles)
    merged = Region.merge(tiles)
    assert merged.world == WORLD and merged.bounds == original.bounds
    assert merged.blocks.dtype == np.int16
    assert len(set(merged.palette)) == len(merged.palette) and merged.palette[0] == AIR
    np.testing.assert_array_equal(_names(merged), _names(original))
    assert merged.counts() == original.counts()
    with pytest.raises(ValueError):
        Region.merge([])
    with pytest.raises(ValueError):
        Region.merge([tiles[0], Region.empty("other", tiles[0].bounds)])


def test_merge_later_tile_wins_where_tiles_overlap() -> None:
    a = Region.empty(WORLD, Bounds((0, 0, 0), (3, 0, 0)), fill="minecraft:stone")
    b = Region.empty(WORLD, Bounds((2, 0, 0), (5, 0, 0)), fill="minecraft:dirt")
    assert [Region.merge([a, b]).get(x, 0, 0) for x in range(6)] == ["minecraft:stone"] * 2 + ["minecraft:dirt"] * 4
    assert [Region.merge([b, a]).get(x, 0, 0) for x in range(6)] == ["minecraft:stone"] * 4 + ["minecraft:dirt"] * 2


def test_merge_fills_a_gap_between_tiles_with_air() -> None:
    a = Region.empty(WORLD, Bounds((0, 0, 0), (3, 0, 0)), fill="minecraft:stone")
    b = Region.empty(WORLD, Bounds((6, 0, 0), (6, 0, 0)), fill="minecraft:dirt")
    merged = Region.merge([a, b])
    assert merged.bounds == Bounds((0, 0, 0), (6, 0, 0))
    assert merged.get(4, 0, 0) == AIR == merged.get(5, 0, 0)
    assert merged.counts() == {AIR: 2, "minecraft:stone": 4, "minecraft:dirt": 1}


def test_from_rle_rejects_a_payload_from_another_world() -> None:
    payload = Region.empty(WORLD, Bounds((0, 0, 0), (1, 1, 1))).to_rle()
    assert Region.from_rle(WORLD, payload).world == WORLD
    with pytest.raises(ValueError, match="world"):
        Region.from_rle("other", payload)
    del payload["world"]
    assert Region.from_rle("other", payload).world == "other"


def test_region_rejects_blocks_that_are_not_int16() -> None:
    with pytest.raises(ValueError, match="int16"):
        Region(WORLD, Bounds((0, 0, 0), (0, 0, 0)), np.zeros((1, 1, 1), dtype=np.int32), [AIR])
