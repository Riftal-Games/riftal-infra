"""In-process stand-in for the DesignBridge plugin, so no test needs a server.

Speaks the wire contract on a loopback port from a daemon thread. Each fault
knob applies to the next request only and resets itself; ``omit_top`` stands.

Jobs: ``queue_next`` is how many ``get_job`` polls the next job needs before it
settles, ``fail_next_job`` is the error text it settles with, ``slow_op`` takes
``steps`` and ``total`` and reports progress. Every ``cancel_job`` seen is kept
in ``cancelled``.
"""

from __future__ import annotations

import asyncio
import json
import threading
from typing import Any

import numpy as np

from designer.blocks import encode_rle
from designer.region import MAX_EDGE, Bounds, Bounds2D


class FakeOpError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class FakeWorld:
    """Flat terrain: stone below ``SURFACE``, grass on it, air above and outside ``extent`` or y 0..127.

    Air is last in the palette on purpose, so the toolkit's remap to index 0 is exercised.
    """

    PALETTE = ["minecraft:stone", "minecraft:grass_block", "minecraft:air"]
    SURFACE, HEIGHT = 63, 128

    def __init__(self, extent: tuple[tuple[int, int], tuple[int, int]] = ((0, 0), (255, 255))) -> None:
        self.extent = Bounds2D(*extent)

    def _inside(self, x: np.ndarray, z: np.ndarray) -> np.ndarray:
        (x0, z0), (x1, z1) = self.extent.min, self.extent.max
        return (x >= x0) & (x <= x1) & (z >= z0) & (z <= z1)

    def blocks(self, bounds: Bounds) -> np.ndarray:
        """Palette indices ``[y][z][x]`` inside ``bounds``."""
        xs, ys, zs = (np.arange(lo, hi + 1) for lo, hi in zip(bounds.min, bounds.max))
        y, z, x = ys[:, None, None], zs[None, :, None], xs[None, None, :]
        column = np.where(y < self.SURFACE, 0, np.where(y == self.SURFACE, 1, 2))
        inside = self._inside(x, z) & (y >= 0) & (y < self.HEIGHT)
        return np.where(inside, column, 2).astype(np.int16)

    def heightmap(self, bounds: Bounds2D) -> tuple[np.ndarray, np.ndarray]:
        xs, zs = (np.arange(lo, hi + 1) for lo, hi in zip(bounds.min, bounds.max))
        inside = self._inside(xs[None, :], zs[:, None])
        return np.where(inside, self.SURFACE, -1), np.where(inside, 1, 2)


class FakeBridge:
    def __init__(self, token: str = "hunter2-do-not-print") -> None:
        self.token = token
        self.designer = True
        self.drop_next_response = False
        self.delay_next = 0.0
        self.wrong_id_next = False
        self.pad_next = 0
        self.queue_next = 0
        self.fail_next_job: str | None = None
        self.omit_top = False
        self.worlds: dict[str, FakeWorld] = {"design": FakeWorld()}
        self.requests: list[dict[str, Any]] = []
        self.jobs: dict[str, dict[str, Any]] = {}
        self.cancelled: list[str] = []
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
                response = {"id": request_id, **self._dispatch(request)}
                if self.pad_next:
                    self.pad_next, response["pad"] = 0, "x" * self.pad_next
                await self._reply(writer, response)
        finally:
            writer.close()

    async def _reply(self, writer: asyncio.StreamWriter, response: dict[str, Any]) -> None:
        writer.write(json.dumps(response).encode() + b"\n")
        await writer.drain()

    def _dispatch(self, request: dict[str, Any]) -> dict[str, Any]:
        handler = getattr(self, f"op_{request.get('op')}", None)
        if handler is None:
            return {"ok": False, "error": f"unknown op {request.get('op')!r}", "code": "UNKNOWN_OP"}
        try:
            return {"ok": True, "data": handler(request.get("args") or {})}
        except FakeOpError as exc:
            return {"ok": False, "error": str(exc), "code": exc.code}

    def _world(self, name: str) -> FakeWorld:
        if name not in self.worlds:
            raise FakeOpError("WORLD_NOT_FOUND", f"no world {name!r}")
        return self.worlds[name]

    def _bounds(self, args: dict[str, Any], cls: type[Bounds] | type[Bounds2D]) -> Any:
        box = cls.from_json(args["bounds"])
        if max(box.size) > MAX_EDGE:
            raise FakeOpError("BOUNDS_TOO_LARGE", f"edge {max(box.size)} over {MAX_EDGE}")
        return box

    def _job(self, op: str, result: dict[str, Any], steps: int = 0, total: int | None = None) -> dict[str, Any]:
        steps, self.queue_next = max(steps, self.queue_next), 0
        error, self.fail_next_job = self.fail_next_job, None
        job_id = f"j{len(self.requests)}"
        self.jobs[job_id] = {
            "job": job_id, "op": op, "result": result, "error": error, "steps": steps, "polls": 0,
            "total": steps if total is None else total, "cancelled": False,
        }
        return self._status(job_id)

    def _status(self, job_id: str) -> dict[str, Any]:
        job = self.jobs.get(job_id)
        if job is None:
            raise FakeOpError("JOB_NOT_FOUND", f"no job {job_id!r}")
        settled = job["polls"] >= job["steps"]
        if job["cancelled"]:
            state = "cancelled"
        elif not settled:
            state = "queued" if job["polls"] == 0 else "running"
        else:
            state = "failed" if job["error"] else "done"
        done = min(job["polls"], job["steps"]) * job["total"] // max(job["steps"], 1)
        status = {"job": job_id, "op": job["op"], "state": state, "progress": {"done": done, "total": job["total"]}, "elapsed_ms": 0}
        if state == "done":
            status["result"] = job["result"]
        if state == "failed":
            status["error"] = job["error"]
        return status

    def op_get_job(self, args: dict[str, Any]) -> dict[str, Any]:
        job = self.jobs.get(args["job"])
        if job is not None and not job["cancelled"]:
            job["polls"] += 1
        return self._status(args["job"])

    def op_cancel_job(self, args: dict[str, Any]) -> dict[str, Any]:
        self.cancelled.append(args["job"])
        status = self._status(args["job"])
        if status["state"] not in ("done", "failed"):
            self.jobs[args["job"]]["cancelled"] = True
        return self._status(args["job"])

    def op_slow_op(self, args: dict[str, Any]) -> dict[str, Any]:
        return self._job("slow_op", {"echo": args.get("echo")}, steps=int(args.get("steps", 3)), total=args.get("total"))

    def op_ping(self, args: dict[str, Any]) -> dict[str, Any]:
        return {"pong": True, "tick": len(self.requests)}

    def op_server_info(self, args: dict[str, Any]) -> dict[str, Any]:
        return {"designer": self.designer, "pmmp_version": "fake", "protocol": 2168, "worlds": []}

    def op_list_worlds(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        return [{"name": name, "loaded": True} for name in self.worlds]

    def op_load_world(self, args: dict[str, Any]) -> dict[str, Any]:
        self._world(args["name"])
        return {"spawn": [0, FakeWorld.SURFACE + 1, 0], "seed": 0, "generator": "flat"}

    def op_create_world(self, args: dict[str, Any]) -> dict[str, Any]:
        if args["name"] in self.worlds:
            raise FakeOpError("WORLD_EXISTS", f"world {args['name']!r} exists")
        self.worlds[args["name"]] = FakeWorld()
        return {}

    def op_save_world(self, args: dict[str, Any]) -> dict[str, Any]:
        self._world(args["name"])
        return {}

    def op_get_region(self, args: dict[str, Any]) -> dict[str, Any]:
        world, box = self._world(args["world"]), self._bounds(args, Bounds)
        payload = encode_rle(world.blocks(box), FakeWorld.PALETTE, origin=box.min)
        payload["world"] = args["world"]
        return self._job("get_region", payload)

    def op_get_heightmap(self, args: dict[str, Any]) -> dict[str, Any]:
        world, box = self._world(args["world"]), self._bounds(args, Bounds2D)
        heights, top = world.heightmap(box)
        result = {**box.to_json(), "heights": heights.ravel().tolist(), "palette": FakeWorld.PALETTE}
        if not self.omit_top:
            result["top"] = top.ravel().tolist()
        return self._job("get_heightmap", result)
