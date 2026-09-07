import pytest

from designer.blocks import AIR
from designer.bridge import Bridge
from designer.region import Bounds, Region
from tests.fake_bridge import FakeBridge


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
