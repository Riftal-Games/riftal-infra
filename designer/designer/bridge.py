"""Synchronous client for the DesignBridge plugin: newline-delimited JSON over TCP.

One request in flight at a time. The token is attached on send and never appears
in a message, a repr or an exception. Only ``IDEMPOTENT_OPS`` are resent after a
lost connection; any other op sent but not answered raises ``sent_unconfirmed``.
"""

from __future__ import annotations

import itertools
import json
import socket
import threading
import time
from typing import Any

IDEMPOTENT_OPS = frozenset({"ping", "server_info", "list_worlds", "get_job", "cancel_job", "list_entities", "tail_log"})
RECONNECT_BACKOFF = (0.25, 0.5, 1.0, 2.0, 4.0)


class BridgeError(Exception):
    """Base class for every error this module raises."""


class BridgeConnectionError(BridgeError):
    def __init__(self, message: str, *, detail: str | None = None) -> None:
        super().__init__(message)
        self.detail = detail


class BridgeProtocolError(BridgeError):
    """The server answered with something that is not a response to the request."""


class BridgeOpError(BridgeError):
    def __init__(self, code: str, op: str, args: dict[str, Any], message: str) -> None:
        super().__init__(f"{op} failed with {code}: {message}")
        self.code, self.op, self.op_args, self.message = code, op, args, message

    # ``Exception.args`` would be the message tuple; a handler wants the op's arguments.
    args = property(lambda self: self.op_args)


class Bridge:
    def __init__(
        self, host: str, port: int, token: str, *, timeout: float = 30.0,
        connect_timeout: float = 5.0, max_retries: int = 5, max_line_bytes: int = 64 << 20,
    ) -> None:
        self.host, self.port, self._token = host, port, token
        self.timeout, self.connect_timeout = timeout, connect_timeout
        self.max_retries, self.max_line_bytes = max_retries, max_line_bytes
        self._sock: socket.socket | None = None
        self._buf = bytearray()
        self._ids = itertools.count(1)
        self._lock = threading.Lock()
        self._info: tuple[float, dict[str, Any]] | None = None

    def __repr__(self) -> str:
        return f"Bridge({self.host!r}, {self.port})"

    def __enter__(self) -> Bridge:
        self.connect()
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    @property
    def connected(self) -> bool:
        return self._sock is not None

    def connect(self) -> None:
        with self._lock:
            self._connect_locked()

    def close(self) -> None:
        with self._lock:
            self._drop()

    def call(self, op: str, **args: Any) -> Any:
        with self._lock:
            return self._call_locked(op, args)

    def ping(self) -> float:
        start = time.perf_counter()
        self.call("ping")
        return time.perf_counter() - start

    def server_info(self, *, refresh: bool = False) -> dict[str, Any]:
        if refresh or self._info is None or time.monotonic() - self._info[0] > 30.0:
            self._info = (time.monotonic(), self.call("server_info"))
        return self._info[1]

    def is_designer(self) -> bool:
        return self.server_info().get("designer") is True

    def _connect_locked(self) -> None:
        if self._sock is None:
            try:
                self._sock = socket.create_connection((self.host, self.port), timeout=self.connect_timeout)
            except OSError as exc:
                raise BridgeConnectionError(f"cannot connect to {self.host}:{self.port}: {exc}") from exc
            self._sock.settimeout(self.timeout)

    def _drop(self) -> None:
        if self._sock is not None:
            self._sock.close()
        self._sock, self._buf = None, bytearray()

    def _call_locked(self, op: str, args: dict[str, Any]) -> Any:
        for attempt in itertools.count():
            request_id, sent = next(self._ids), False
            try:
                self._connect_locked()
                self._send(request_id, op, args)
                sent = True
                return self._interpret(self._recv_line(), request_id, op, args)
            except (OSError, BridgeConnectionError) as exc:
                self._drop()
                unconfirmed = sent and op not in IDEMPOTENT_OPS
                if sent and isinstance(exc, TimeoutError):
                    detail = "sent_unconfirmed" if unconfirmed else "timeout"
                    raise BridgeConnectionError(f"{op}: no response within {self.timeout}s", detail=detail) from exc
                if unconfirmed:
                    raise BridgeConnectionError(f"{op}: connection lost after send: {exc}", detail="sent_unconfirmed") from exc
                if attempt >= self.max_retries:
                    raise BridgeConnectionError(f"{op}: giving up after {attempt} retries: {exc}") from exc
                time.sleep(RECONNECT_BACKOFF[min(attempt, len(RECONNECT_BACKOFF) - 1)])

    def _send(self, request_id: int, op: str, args: dict[str, Any]) -> None:
        request = {"id": request_id, "token": self._token, "op": op, "args": args}
        self._sock.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")

    def _recv_line(self) -> bytes:
        while (end := self._buf.find(b"\n")) < 0:
            if len(self._buf) > self.max_line_bytes:
                self._drop()
                raise BridgeProtocolError(f"response exceeds {self.max_line_bytes} bytes")
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed by server")
            self._buf += chunk
        line = bytes(self._buf[:end])
        del self._buf[: end + 1]
        return line

    def _interpret(self, line: bytes, request_id: int, op: str, args: dict[str, Any]) -> Any:
        try:
            response = json.loads(line)
        except ValueError:
            response = None
        got = response.get("id") if isinstance(response, dict) else None
        if got != request_id:
            self._drop()
            raise BridgeProtocolError(f"response id {got!r} does not match request {request_id}")
        if response.get("ok") is True:
            return response.get("data")
        code = str(response.get("code", "INTERNAL"))
        if code == "AUTH":
            self._drop()
        raise BridgeOpError(code, op, args, str(response.get("error", "")))
