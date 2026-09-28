from itertools import product

import numpy as np
import pytest

from designer.blocks import AIR
from designer.bridge import Bridge, BridgeOpError, JobFailed
from designer.region import EMPTY_Y, Bounds, Bounds2D, Heightmap, Region, fetch_heightmap, fetch_region, heightmap_from_region
from tests.fake_bridge import FakeBridge, FakeWorld

WORLD = "design"
STONE, GRASS = "minecraft:stone", "minecraft:grass_block"


def _calls(fake: FakeBridge, op: str) -> list[dict]:
    return [r for r in fake.requests if r["op"] == op]


def _names(palette: list[str], indices: np.ndarray) -> np.ndarray:
    return np.array(palette)[indices]


def test_heightmap_fetch_makes_nine_calls_over_300_square_and_merges(fake: FakeBridge, bridge: Bridge) -> None:
    fake.worlds[WORLD] = FakeWorld(((0, 0), (199, 299)))
    flat = Bounds2D((0, 0), (299, 299))
    heightmap = fetch_heightmap(bridge, WORLD, flat, need_top=True)
    assert len(_calls(fake, "get_heightmap")) == 9 and not _calls(fake, "get_region")
    assert heightmap.bounds == flat and heightmap.heights.shape == (300, 300) and heightmap.heights.dtype == np.int16
    assert (heightmap.heights[:, :200] == 63).all() and (heightmap.heights[:, 200:] == EMPTY_Y).all()
    assert heightmap.height(199, 299) == 63 and heightmap.height(200, 0) is None
    assert heightmap.top_name(150, 150) == GRASS and heightmap.top_name(250, 250) == AIR


def test_heightmap_without_server_top_falls_back_to_a_region(fake: FakeBridge, bridge: Bridge) -> None:
    fake.omit_top = True
    flat = Bounds2D((10, 10), (139, 39))
    heightmap = fetch_heightmap(bridge, WORLD, flat, need_top=True)
    regions = _calls(fake, "get_region")
    assert len(_calls(fake, "get_heightmap")) == 2 and len(regions) == 2
    assert all(r["args"]["bounds"]["min"][1] == 63 == r["args"]["bounds"]["max"][1] for r in regions)
    assert (heightmap.heights == 63).all() and heightmap.top_name(20, 20) == GRASS
    plain = fetch_heightmap(bridge, WORLD, flat)
    assert plain.top is None and len(_calls(fake, "get_region")) == 2
    with pytest.raises(ValueError, match="need_top"):
        plain.top_name(20, 20)


def test_region_fetch_tiles_and_merges_equal_to_a_direct_build(fake: FakeBridge, bridge: Bridge) -> None:
    box = Bounds((-50, 0, -50), (149, 127, 149))
    region = fetch_region(bridge, WORLD, box)
    assert len(_calls(fake, "get_region")) == 4 and region.bounds == box and region.palette[0] == AIR
    np.testing.assert_array_equal(_names(region.palette, region.blocks), _names(FakeWorld.PALETTE, fake.worlds[WORLD].blocks(box)))
    assert region.counts()[GRASS] == 150 * 150


def test_fake_refuses_big_bounds_and_unknown_worlds(fake: FakeBridge, bridge: Bridge) -> None:
    with pytest.raises(BridgeOpError, match="BOUNDS_TOO_LARGE"):
        bridge.call("get_region", world=WORLD, bounds=Bounds((0, 0, 0), (128, 0, 0)).to_json())
    assert fetch_region(bridge, WORLD, Bounds((0, 0, 0), (128, 0, 0)), max_edge=64).bounds.size == (129, 1, 1)
    with pytest.raises(BridgeOpError, match="WORLD_NOT_FOUND"):
        fetch_heightmap(bridge, "nowhere", Bounds2D((0, 0), (0, 0)))


def test_queued_region_job_is_polled_to_completion(fake: FakeBridge, bridge: Bridge) -> None:
    fake.queue_next = 3
    box = Bounds((0, 60, 0), (3, 65, 3))
    region = fetch_region(bridge, WORLD, box)
    assert [r["op"] for r in fake.requests] == ["get_region"] + ["get_job"] * 3
    assert region.bounds == box and region.counts()[GRASS] == 16
    fake.queue_next = 2
    assert fetch_heightmap(bridge, WORLD, Bounds2D((0, 0), (3, 3))).height(1, 1) == 63
    assert [r["op"] for r in fake.requests[4:]] == ["get_heightmap"] + ["get_job"] * 2


def test_failed_fetch_surfaces_the_server_text(fake: FakeBridge, bridge: Bridge) -> None:
    fake.fail_next_job = "CHUNK_NOT_GENERATED: chunk 0,0 has no terrain"
    with pytest.raises(JobFailed, match="chunk 0,0 has no terrain"):
        fetch_region(bridge, WORLD, Bounds((0, 0, 0), (0, 0, 0)))
    fake.fail_next_job, fake.queue_next = "CHUNK_NOT_GENERATED: chunk 0,0 has no terrain", 2
    with pytest.raises(JobFailed, match="chunk 0,0 has no terrain"):
        fetch_heightmap(bridge, WORLD, Bounds2D((0, 0), (0, 0)))
    assert [r["op"] for r in fake.requests] == ["get_region", "get_heightmap", "get_job", "get_job"]


def test_fake_world_ops(bridge: Bridge) -> None:
    assert bridge.call("list_worlds") == [{"name": WORLD, "loaded": True}]
    bridge.call("create_world", name="fresh", generator="flat")
    assert bridge.call("load_world", name="fresh")["generator"] == "flat"
    assert bridge.call("save_world", name="fresh") == {}
    with pytest.raises(BridgeOpError, match="WORLD_EXISTS"):
        bridge.call("create_world", name="fresh", generator="flat")
    with pytest.raises(BridgeOpError, match="WORLD_NOT_FOUND"):
        bridge.call("save_world", name="gone")


def _region_with_a_tree() -> Region:
    region = Region.empty(WORLD, Bounds((0, 60, 0), (4, 75, 4)), fill=STONE)
    region.blocks[4:] = 0
    for y in range(64, 69):
        region.set(2, y, 2, "minecraft:oak_log[pillar_axis=y]")
    for x, y, z in product(range(1, 4), range(68, 71), range(1, 4)):
        if region.get(x, y, z) == AIR:
            region.set(x, y, z, "minecraft:oak_leaves")
    region.set(0, 64, 0, "minecraft:torch")
    region.set(4, 64, 4, "minecraft:red_flower")
    region.blocks[:, 0, 4] = 0
    return region


def test_heightmap_from_region_canopy_versus_ground() -> None:
    region = _region_with_a_tree()
    canopy = heightmap_from_region(region)
    assert canopy.bounds == Bounds2D((0, 0), (4, 4)) and canopy.heights.dtype == np.int16
    assert (canopy.height(2, 2), canopy.top_name(2, 2)) == (70, "minecraft:oak_leaves")
    assert (canopy.height(0, 0), canopy.top_name(0, 0)) == (64, "minecraft:torch")
    assert (canopy.height(4, 4), canopy.top_name(4, 4)) == (64, "minecraft:red_flower")
    assert (canopy.height(0, 4), canopy.top_name(0, 4)) == (63, STONE)
    assert (canopy.height(4, 0), canopy.top_name(4, 0)) == (None, AIR)
    ground = heightmap_from_region(region, ground=True)
    expected = np.full((5, 5), 63, dtype=np.int16)
    expected[0, 4] = EMPTY_Y
    np.testing.assert_array_equal(ground.heights, expected)
    assert set(_names(ground.palette, ground.top).ravel()) == {STONE, AIR}
    with pytest.raises(ValueError, match="int16"):
        Heightmap(WORLD, canopy.bounds, canopy.heights.astype(np.int32))
