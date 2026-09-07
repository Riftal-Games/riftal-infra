import socket

import pytest

from designer.bridge import Bridge, BridgeConnectionError, BridgeError, BridgeOpError, BridgeProtocolError
from tests.fake_bridge import FakeBridge


def test_ping_round_trips(bridge: Bridge) -> None:
    assert bridge.call("ping")["pong"] is True
    assert 0 < bridge.ping() < 1


def test_request_ids_are_monotonic(fake: FakeBridge, bridge: Bridge) -> None:
    for _ in range(3):
        bridge.call("ping")
    assert [request["id"] for request in fake.requests] == [1, 2, 3]


def test_op_error_surfaces_code_op_and_args(bridge: Bridge) -> None:
    with pytest.raises(BridgeOpError, match="UNKNOWN_OP") as excinfo:
        bridge.call("no_such_op", world="lobby")
    assert (excinfo.value.code, excinfo.value.op, excinfo.value.args) == ("UNKNOWN_OP", "no_such_op", {"world": "lobby"})


def test_auth_failure_closes_the_connection(fake: FakeBridge) -> None:
    with Bridge("127.0.0.1", fake.port, "wrong", max_retries=0) as client:
        with pytest.raises(BridgeOpError) as excinfo:
            client.call("ping")
        assert (excinfo.value.code, client.connected) == ("AUTH", False)


def test_id_mismatch_drops_socket_and_next_call_reconnects(fake: FakeBridge, bridge: Bridge) -> None:
    fake.wrong_id_next = True
    with pytest.raises(BridgeProtocolError, match="does not match"):
        bridge.call("ping")
    assert bridge.connected is False
    assert bridge.call("ping")["pong"] is True
    assert bridge.connected is True


def test_slow_response_times_out(fake: FakeBridge) -> None:
    fake.delay_next = 0.5
    with Bridge("127.0.0.1", fake.port, fake.token, timeout=0.05, max_retries=0) as client:
        with pytest.raises(BridgeConnectionError, match="within 0.05s") as excinfo:
            client.call("ping")
    assert excinfo.value.detail == "timeout"


def test_dropped_response_on_idempotent_op_is_retried(fake: FakeBridge, bridge: Bridge) -> None:
    fake.drop_next_response = True
    assert bridge.call("ping")["pong"] is True
    assert [request["id"] for request in fake.requests] == [1, 2]


def test_dropped_response_on_mutating_op_is_not_retried(fake: FakeBridge, bridge: Bridge) -> None:
    fake.drop_next_response = True
    with pytest.raises(BridgeConnectionError) as excinfo:
        bridge.call("fill", world="lobby")
    assert excinfo.value.detail == "sent_unconfirmed"
    assert [request["op"] for request in fake.requests] == ["fill"]


def test_is_designer_follows_server_info_and_caches(fake: FakeBridge, bridge: Bridge) -> None:
    fake.designer = False
    assert bridge.is_designer() is False
    fake.designer = True
    assert bridge.is_designer() is False
    bridge.server_info(refresh=True)
    assert bridge.is_designer() is True


def test_token_never_appears_in_repr_or_errors(fake: FakeBridge, bridge: Bridge) -> None:
    token = fake.token
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        closed_port = probe.getsockname()[1]
    errors: list[BridgeError] = []
    fake.wrong_id_next = True
    for client, op in (
        (bridge, "ping"),
        (bridge, "no_such_op"),
        (Bridge("127.0.0.1", fake.port, token + "x", max_retries=0), "ping"),
        (Bridge("127.0.0.1", closed_port, token, max_retries=0), "ping"),
    ):
        with pytest.raises(BridgeError) as excinfo:
            client.call(op, token=token)
        errors.append(excinfo.value)
    assert token not in repr(bridge)
    assert [type(error) for error in errors] == [BridgeProtocolError, BridgeOpError, BridgeOpError, BridgeConnectionError]
    assert all(token not in str(error) and token not in repr(error) for error in errors)
