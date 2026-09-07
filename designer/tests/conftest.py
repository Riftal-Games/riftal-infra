import pytest

from designer.bridge import Bridge
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
