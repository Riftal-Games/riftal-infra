"""In-process stand-in for the DesignBridge plugin, so no test needs a server.

Speaks the wire contract on a loopback port from a daemon thread. Each fault
knob applies to the next request only and resets itself.
"""

from __future__ import annotations

import asyncio
import json
import threading
from typing import Any


class FakeBridge:
    def __init__(self, token: str = "hunter2-do-not-print") -> None:
        self.token = token
        self.designer = True
        self.drop_next_response = False
        self.delay_next = 0.0
        self.wrong_id_next = False
        self.requests: list[dict[str, Any]] = []
        self.port = 0
        self._loop = asyncio.new_event_loop()
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> int:
        self._thread.start()
        self._ready.wait(5)
        return self.port

    def stop(self) -> None:
        self._loop.call_soon_threadsafe(self._server.close)
        self._thread.join(5)

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._serve())
        except asyncio.CancelledError:
            pass
        finally:
            pending = asyncio.all_tasks(self._loop)
            for task in pending:
                task.cancel()
            self._loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
            self._loop.close()

    async def _serve(self) -> None:
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", 0)
        self.port = self._server.sockets[0].getsockname()[1]
        self._ready.set()
        await self._server.serve_forever()

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while line := await reader.readline():
                request = json.loads(line)
                self.requests.append(request)
                request_id = request.get("id")
                if request.get("token") != self.token:
                    await self._reply(writer, {"id": request_id, "ok": False, "error": "bad token", "code": "AUTH"})
                    break
                if self.delay_next:
                    self.delay_next, delay = 0.0, self.delay_next
                    await asyncio.sleep(delay)
                if self.drop_next_response:
                    self.drop_next_response = False
                    break
                if self.wrong_id_next:
                    self.wrong_id_next, request_id = False, -1
                await self._reply(writer, {"id": request_id, **self._dispatch(request)})
        finally:
            writer.close()

    async def _reply(self, writer: asyncio.StreamWriter, response: dict[str, Any]) -> None:
        writer.write(json.dumps(response).encode() + b"\n")
        await writer.drain()

    def _dispatch(self, request: dict[str, Any]) -> dict[str, Any]:
        handler = getattr(self, f"op_{request.get('op')}", None)
        if handler is None:
            return {"ok": False, "error": f"unknown op {request.get('op')!r}", "code": "UNKNOWN_OP"}
        return {"ok": True, "data": handler(request.get("args") or {})}

    def op_ping(self, args: dict[str, Any]) -> dict[str, Any]:
        return {"pong": True, "tick": len(self.requests)}

    def op_server_info(self, args: dict[str, Any]) -> dict[str, Any]:
        return {"designer": self.designer, "pmmp_version": "fake", "protocol": 2168, "worlds": []}
