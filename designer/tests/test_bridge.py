import socket

import pytest

from designer.bridge import (
    Bridge, BridgeConnectionError, BridgeError, BridgeOpError, BridgeProtocolError, JobCancelled, JobFailed, JobTimeout,
)
from tests.fake_bridge import FakeBridge


def _ops(fake: FakeBridge) -> list[str]:
    return [request["op"] for request in fake.requests]


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
    assert (excinfo.value.code, excinfo.value.op, excinfo.value.op_args) == ("UNKNOWN_OP", "no_such_op", {"world": "lobby"})
    assert excinfo.value.args == (str(excinfo.value),)


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


def test_oversize_line_is_refused_even_when_it_arrives_whole(fake: FakeBridge) -> None:
    fake.pad_next = 4096
    with Bridge("127.0.0.1", fake.port, fake.token, max_retries=0, max_line_bytes=1024) as client:
        with pytest.raises(BridgeProtocolError, match="exceeds 1024 bytes"):
            client.call("ping")
        assert client.connected is False
        assert client.call("ping")["pong"] is True


def test_call_job_polls_with_progress_and_reports_each_change_once(fake: FakeBridge, bridge: Bridge) -> None:
    seen: list[tuple[int, int]] = []
    status = bridge.call_job("slow_op", poll=0.01, on_progress=lambda done, total: seen.append((done, total)), steps=4, total=2, echo="hi")
    assert (status["state"], status["result"]) == ("done", {"echo": "hi"})
    assert _ops(fake) == ["slow_op"] + ["get_job"] * 4
    assert seen == [(0, 2), (1, 2), (2, 2)]


def test_inline_done_takes_no_poll(fake: FakeBridge, bridge: Bridge) -> None:
    assert bridge.call_job("slow_op", steps=0)["state"] == "done"
    assert _ops(fake) == ["slow_op"]


def test_failed_job_carries_the_server_text(fake: FakeBridge, bridge: Bridge) -> None:
    fake.fail_next_job = "CHUNK_NOT_GENERATED: chunk 3,4 has no terrain"
    with pytest.raises(JobFailed, match="chunk 3,4 has no terrain") as excinfo:
        bridge.call_job("slow_op", poll=0.01, steps=2)
    assert (excinfo.value.job, excinfo.value.error) == ("j1", "CHUNK_NOT_GENERATED: chunk 3,4 has no terrain")
    assert _ops(fake) == ["slow_op", "get_job", "get_job"]


def test_cancelled_job_raises(fake: FakeBridge, bridge: Bridge) -> None:
    job_id = bridge.call("slow_op", steps=3)["job"]
    assert bridge.call("cancel_job", job=job_id)["state"] == "cancelled"
    with pytest.raises(JobCancelled, match=job_id):
        bridge.wait_job(job_id, poll=0.01)


def test_timeout_cancels_the_job_and_keeps_the_last_status(fake: FakeBridge, bridge: Bridge) -> None:
    with pytest.raises(JobTimeout, match="still 'running'") as excinfo:
        bridge.call_job("slow_op", poll=0.01, timeout=0.1, steps=1000)
    assert fake.cancelled == [excinfo.value.job] and excinfo.value.last_status["state"] == "running"
    assert _ops(fake)[-1] == "cancel_job" and 2 < _ops(fake).count("get_job") < 20


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
