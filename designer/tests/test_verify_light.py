import numpy as np
import pytest

from designer.blocks import AIR, RLEError
from designer.bridge import Bridge
from designer.region import Bounds, LightRegion, Region, decode_light, fetch_light
from designer.verify import HOLES_REPORTED, LIGHT_WORST, light_ok, no_holes
from tests.fake_bridge import FakeBridge

WORLD = "design"
BOX = Bounds((0, 0, 0), (3, 3, 3))


def _light(block: np.ndarray, sky: np.ndarray | None = None) -> LightRegion:
    return LightRegion(WORLD, BOX, block, np.zeros(BOX.shape, dtype=np.uint8) if sky is None else sky)


def test_decode_light_splits_the_packed_palette() -> None:
    box = Bounds((0, 0, 0), (1, 1, 1))
    payload = {
        "world": WORLD, **box.to_json(), "order": "yzx", "palette": [15 << 4 | 3, 7 << 4, 12],
        "runs": [[0, 3], [1, 4], [2, 1]], "volume": 8,
        "chunks": [{"cx": 0, "cz": 0, "light": "stale"}, {"cx": 1, "cz": 0, "light": "fresh"}],
    }
    light = decode_light(payload)
    assert light.world == WORLD and light.bounds == box and light.block.dtype == light.sky.dtype == np.uint8
    assert light.block.ravel().tolist() == [3, 3, 3, 0, 0, 0, 0, 12]
    assert light.sky.ravel().tolist() == [15, 15, 15, 7, 7, 7, 7, 0]
    assert light.stale_chunks == [(0, 0)] and light.level(1, 1, 1) == (12, 0)
    with pytest.raises(RLEError, match="0..255"):
        decode_light({**payload, "palette": [256, 0, 0]})
    with pytest.raises(ValueError, match="expected 'other'"):
        decode_light(payload, "other")
    unnamed = {k: v for k, v in payload.items() if k != "world"}
    assert decode_light(unnamed, WORLD).world == WORLD
    with pytest.raises(ValueError, match="names no world"):
        decode_light(unnamed)


def test_fetch_light_tiles_and_merges_the_stale_list(fake: FakeBridge, bridge: Bridge) -> None:
    fake.stale_chunks = [(4, 4), (0, 0), (8, 8)]
    box = Bounds((-50, 40, -50), (149, 70, 149))
    light = fetch_light(bridge, WORLD, box)
    calls = [r for r in fake.requests if r["op"] == "get_light"]
    assert len(calls) == 4 and light.bounds == box and light.block.shape == box.shape and light.sky.dtype == np.uint8
    assert not light.block.any()
    assert light.level(100, 64, 100) == (0, 15) and light.level(100, 63, 100) == (0, 14) and light.level(100, 49, 100) == (0, 0)
    assert light.level(-10, 40, -10) == (0, 15)
    assert light.stale_chunks == [(0, 0), (4, 4), (8, 8)]


def test_light_ok_passes_a_lit_box_and_names_the_darkest_cells_first() -> None:
    lit = light_ok(_light(np.full(BOX.shape, 8, dtype=np.uint8)), 8)
    assert lit.ok and lit.data == {"below": 0, "fraction": 0.0} and lit.coords == []
    block = np.full(BOX.shape, 8, dtype=np.uint8)
    block[0, 0] = 0
    block[3] = 6
    block[1, 2, 1] = 3
    block[2, 0, 0] = 7
    found = light_ok(_light(block), 8)
    assert not found.ok and found.detail == "22 of 64 cells below block light 8"
    assert found.data == {"below": 22, "fraction": 22 / 64}
    assert len(found.coords) == LIGHT_WORST
    assert found.coords[:5] == [(0, 0, 0), (1, 0, 0), (2, 0, 0), (3, 0, 0), (1, 1, 2)]
    assert found.coords[5:] == [(x, 3, z) for z in range(4) for x in range(4)][:15]


def test_light_ok_kind_max_takes_the_brighter_of_the_two() -> None:
    sky = np.zeros(BOX.shape, dtype=np.uint8)
    sky[2:] = 15
    block = np.zeros(BOX.shape, dtype=np.uint8)
    block[:2] = 10
    assert light_ok(_light(block, sky), 8, kind="sky").data == {"below": 32, "fraction": 0.5}
    assert light_ok(_light(block, sky), 8, kind="block").data["below"] == 32
    assert light_ok(_light(block, sky), 8, kind="max").ok
    with pytest.raises(ValueError, match="kind"):
        light_ok(_light(block, sky), 8, kind="moon")


def test_light_ok_mask_restricts_the_check() -> None:
    sky = np.zeros(BOX.shape, dtype=np.uint8)
    sky[2:] = 15
    mask = np.zeros(BOX.shape, dtype=bool)
    mask[2:] = True
    found = light_ok(_light(np.zeros(BOX.shape, dtype=np.uint8), sky), 15, mask=mask, kind="sky")
    assert found.ok and found.data == {"below": 0, "fraction": 0.0}
    found = light_ok(_light(np.zeros(BOX.shape, dtype=np.uint8), sky), 15, mask=~mask, kind="sky")
    assert not found.ok and found.data == {"below": 32, "fraction": 1.0} and found.coords[0] == (0, 0, 0)
    with pytest.raises(ValueError, match="mask shape"):
        light_ok(_light(np.zeros(BOX.shape, dtype=np.uint8)), 1, mask=mask[0])


def test_no_holes_finds_the_hole_and_nothing_else(flat_plane_with_hole: Region) -> None:
    walkway = np.ones((40, 40), dtype=bool)
    walkway[:3, :3] = False
    found = no_holes(flat_plane_with_hole, 4, walkway)
    assert not found.ok and found.detail == "4 holes in the walkway" and found.data == {"holes": 4, "unmapped": 0}
    assert found.coords == [(19, 3, 19), (20, 3, 19), (19, 3, 20), (20, 3, 20)]
    walkway[19:21, 19:21] = False
    assert no_holes(flat_plane_with_hole, 4, walkway).ok
    flat_plane_with_hole.set(5, 4, 5, "minecraft:stone")
    found = no_holes(flat_plane_with_hole, 4, walkway)
    assert not found.ok and found.coords == [(5, 4, 5)] and found.data == {"holes": 1, "unmapped": 0}
    flat_plane_with_hole.set(5, 4, 5, "minecraft:carpet")
    assert no_holes(flat_plane_with_hole, 4, walkway).ok
    flat_plane_with_hole.fill(Bounds((0, 3, 30), (39, 3, 31)), "minecraft:air")
    found = no_holes(flat_plane_with_hole, 4, walkway)
    assert found.data == {"holes": 80, "unmapped": 0} and len(found.coords) == HOLES_REPORTED and found.coords[0] == (0, 3, 30)
    with pytest.raises(ValueError, match="floor_y"):
        no_holes(flat_plane_with_hole, 0, walkway)
    with pytest.raises(ValueError, match="walkway mask shape"):
        no_holes(flat_plane_with_hole, 4, walkway[0])


def test_a_walkway_over_the_lava_corner_is_a_hole(flat_plane_with_hole: Region) -> None:
    walkway = np.zeros((40, 40), dtype=bool)
    walkway[:3, :3] = True
    found = no_holes(flat_plane_with_hole, 4, walkway)
    assert not found.ok and found.detail == "9 holes in the walkway" and found.data == {"holes": 9, "unmapped": 0}
    assert found.coords == [(x, 3, z) for z in range(3) for x in range(3)]
    flat_plane_with_hole.set(1, 3, 1, "minecraft:water")
    assert no_holes(flat_plane_with_hole, 4, walkway).data == {"holes": 9, "unmapped": 0}
    flat_plane_with_hole.set(1, 3, 1, "minecraft:stone")
    assert no_holes(flat_plane_with_hole, 4, walkway).data == {"holes": 8, "unmapped": 0}


def test_liquid_and_danger_at_walkway_level_are_obstructions(flat_plane_with_hole: Region) -> None:
    walkway = np.zeros((40, 40), dtype=bool)
    walkway[10, 10:12] = True
    flat_plane_with_hole.set(10, 4, 10, "minecraft:water")
    flat_plane_with_hole.set(11, 4, 10, "minecraft:lava")
    found = no_holes(flat_plane_with_hole, 4, walkway)
    assert not found.ok and found.coords == [(10, 4, 10), (11, 4, 10)] and found.data == {"holes": 2, "unmapped": 0}


def test_a_walkway_over_an_unmapped_floor_names_it_after_any_hole(flat_plane_with_hole: Region) -> None:
    walkway = np.zeros((40, 40), dtype=bool)
    walkway[10, 10:13] = True
    flat_plane_with_hole.set(11, 3, 10, "minecraft:info_update")
    flat_plane_with_hole.set(12, 3, 10, "info_update")
    found = no_holes(flat_plane_with_hole, 4, walkway)
    note = "a block the core does not map (minecraft:info_update)"
    assert not found.ok and found.detail == f"2 walkway floor cells are {note}"
    assert found.coords == [(11, 3, 10), (12, 3, 10)] and found.data == {"holes": 0, "unmapped": 2}
    flat_plane_with_hole.set(10, 3, 10, AIR)
    found = no_holes(flat_plane_with_hole, 4, walkway)
    assert found.detail == "1 holes in the walkway" and found.coords == [(10, 3, 10)] and found.data == {"holes": 1, "unmapped": 2}
