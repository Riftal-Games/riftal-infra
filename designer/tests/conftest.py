import numpy as np
import pytest

from designer.blocks import AIR
from designer.bridge import Bridge
from designer.builders.mine_spec import MineSpec
from designer.region import Bounds, Region
from tests.fake_bridge import FakeBridge

MINE_SPEC = {
    "name": "box", "world": "design", "origin": [0, 0, 0], "size": [20, 10, 20], "wall_thickness": 2, "floor_y": 2,
    "entrance": {"side": "north", "width": 3, "height": 3}, "exit_path": {"length": 5, "width": 3},
    "ores": {"stone": 60, "coal_ore": 30, "iron_ore": 10}, "seed": 1, "lights_every": 4, "reset_percent": 60,
}

# Small enough that its blocks are just air and stone, no lights placed (lights_every
# outruns exit_path.length), so it builds clean on the fake bridge's tiny palette too.
SMALL_MINE_SPEC = {
    "name": "tbox", "world": "design", "origin": [0, 0, 0], "size": [7, 6, 7], "wall_thickness": 1, "floor_y": 1,
    "entrance": {"side": "north", "width": 3, "height": 2}, "exit_path": {"length": 2, "width": 3},
    "ores": {"minecraft:stone": 1.0}, "seed": 1, "lights_every": 4, "reset_percent": 60,
}
SMALL_MINE_NAMES = {"tbox", "tbox_interior", "tbox_entrance", "tbox_exit_platform", "tbox_exit", "tbox_spawn", "sell_npc_tbox", "rankup_npc_tbox"}
STONE_PALETTES = {"colors": {}, "palettes": {"test_stone": dict.fromkeys(("wall", "wall_trim", "floor", "ceiling", "light", "sign"), "minecraft:stone")}}


@pytest.fixture
def fake():
    server = FakeBridge()
    server.start()
    yield server
    server.stop()


@pytest.fixture
def bridge(fake: FakeBridge):
    with Bridge("127.0.0.1", fake.port, fake.token, timeout=2.0, max_retries=1) as client:
        yield client


@pytest.fixture
def flat_plane_with_hole() -> Region:
    """40x8x40: stone floor at y=3 under air, a 2x2 hole at the centre, 3x3 lava in the low corner."""
    region = Region.empty("plane", Bounds((0, 0, 0), (39, 7, 39)))
    region.fill(Bounds((0, 3, 0), (39, 3, 39)), "minecraft:stone")
    region.fill(Bounds((19, 3, 19), (20, 3, 20)), AIR)
    region.fill(Bounds((0, 3, 0), (2, 3, 2)), "minecraft:lava")
    return region


@pytest.fixture
def ramp_region() -> Region:
    """30x12x10: floor at y = x // 3 up to x=23, then two blocks higher from x=24 on."""
    region = Region.empty("ramp", Bounds((0, 0, 0), (29, 11, 9)))
    for x in range(30):
        region.fill(Bounds((x, 0, 0), (x, x // 3 if x < 24 else 9, 9)), "minecraft:stone")
    return region


@pytest.fixture
def ramp_with_ceiling(ramp_region: Region) -> Region:
    """The ramp with a solid layer over two blocks of air above its rising floor, so no step up has head room."""
    for x in range(24):
        ramp_region.fill(Bounds((x, x // 3 + 3, 0), (x, x // 3 + 3, 9)), "minecraft:stone")
    return ramp_region


@pytest.fixture
def box_mine_region() -> tuple[Region, MineSpec]:
    """20x10x20 stone box, two-thick walls, interior 60/30/10 stone, coal, iron from seed 1, a 3x3 north opening onto a 3x5 platform, with the padding ring."""
    spec = MineSpec.from_dict(MINE_SPEC)
    geo = spec.geometry()
    region = Region.empty(spec.world, geo.padding.union(geo.exit_platform))
    region.fill(geo.outer, "minecraft:stone")
    lut = np.array([region.index_of(name) for name in spec.ores], dtype=np.int16)
    weights = np.array(list(spec.ores.values())) / sum(spec.ores.values())
    inner = region.sub(geo.interior)
    inner.blocks[...] = lut[np.random.default_rng(spec.seed).choice(len(lut), size=inner.blocks.shape, p=weights)]
    region.fill(geo.entrance, AIR)
    region.fill(geo.exit_platform, "minecraft:stone")
    return region, spec


@pytest.fixture
def leaky_mine_region(box_mine_region: tuple[Region, MineSpec]) -> tuple[Region, MineSpec]:
    """The box mine with a one-block hole through the east wall at y=3, z=10."""
    region, spec = box_mine_region
    region.fill(Bounds((18, 3, 10), (19, 3, 10)), AIR)
    return region, spec
