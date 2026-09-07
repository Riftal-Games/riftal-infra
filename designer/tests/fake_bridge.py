"""In-process stand-in for the DesignBridge plugin, so no test needs a server.

Speaks the wire contract on a loopback port from a daemon thread. Each fault
knob applies to the next request only and resets itself; ``omit_top`` stands.

Jobs: ``queue_next`` is how many ``get_job`` polls the next job needs before it
settles, ``fail_next_job`` is the error text it settles with, ``slow_op`` takes
``steps`` and ``total`` and reports progress. Every ``cancel_job`` seen is kept
in ``cancelled``. ``stale_chunks`` names the chunks ``get_light`` reports stale.
"""

from __future__ import annotations

import asyncio
import json
import threading
from itertools import product
from typing import Any

import numpy as np

from designer.blocks import encode_rle, format_name, parse_name
from designer.edits import MAX_SET_BLOCKS
from designer.region import MAX_EDGE, Bounds, Bounds2D

ALLOWED_BLOCKS = frozenset({"minecraft:air", "minecraft:stone", "minecraft:grass_block", "minecraft:dirt", "minecraft:oak_planks", "minecraft:glass"})


class FakeOpError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class FakeWorld:
    """Flat terrain: stone below ``SURFACE``, grass on it, air above and outside ``extent`` or y 0..127.

    Air is last in the palette on purpose, so the toolkit's remap to index 0 is exercised.
    Writes land in ``edits`` on top of the terrain, and the heightmap is read from the same ``blocks``.
    """

    PALETTE = ["minecraft:stone", "minecraft:grass_block", "minecraft:air"]
    SURFACE, HEIGHT = 63, 128

    def __init__(self, extent: tuple[tuple[int, int], tuple[int, int]] = ((0, 0), (255, 255))) -> None:
        self.extent = Bounds2D(*extent)
        self.palette = list(self.PALETTE)
        self.edits: dict[tuple[int, int, int], int] = {}

    def _inside(self, x: np.ndarray, z: np.ndarray) -> np.ndarray:
        (x0, z0), (x1, z1) = self.extent.min, self.extent.max
        return (x >= x0) & (x <= x1) & (z >= z0) & (z <= z1)

    def index_of(self, name: str, where: str = "block") -> int:
        name = format_name(*parse_name(name))
        if name not in ALLOWED_BLOCKS:
            raise FakeOpError("BLOCK_INVALID", f"{where}: unknown block {name!r}")
        if name not in self.palette:
            self.palette.append(name)
        return self.palette.index(name)

    def blocks(self, bounds: Bounds) -> np.ndarray:
        """Palette indices ``[y][z][x]`` inside ``bounds``."""
        xs, ys, zs = (np.arange(lo, hi + 1) for lo, hi in zip(bounds.min, bounds.max))
        y, z, x = ys[:, None, None], zs[None, :, None], xs[None, None, :]
        column = np.where(y < self.SURFACE, 0, np.where(y == self.SURFACE, 1, 2))
        inside = self._inside(x, z) & (y >= 0) & (y < self.HEIGHT)
        out = np.where(inside, column, 2).astype(np.int16)
        for pos, index in self.edits.items():
            if bounds.contains(pos):
                out[bounds.local(pos)] = index
        return out

    def light(self, bounds: Bounds) -> np.ndarray:
        """Packed ``sky << 4 | block``: full sky above the surface, one level less per block under it, no block light."""
        xs, ys, zs = (np.arange(lo, hi + 1) for lo, hi in zip(bounds.min, bounds.max))
        y, z, x = ys[:, None, None], zs[None, :, None], xs[None, None, :]
        depth = np.where(self._inside(x, z), np.maximum(self.SURFACE + 1 - y, 0), 0)
        return np.broadcast_to(np.clip(15 - depth, 0, 15) << 4, bounds.shape).astype(np.uint8)

    def heightmap(self, bounds: Bounds2D) -> tuple[np.ndarray, np.ndarray]:
        (x0, z0), (x1, z1) = bounds.min, bounds.max
        blocks = self.blocks(Bounds((x0, 0, z0), (x1, self.HEIGHT - 1, z1)))
        solid = blocks != self.palette.index("minecraft:air")
        iy = solid.shape[0] - 1 - solid[::-1].argmax(axis=0)
        found = solid.any(axis=0)
        return np.where(found, iy, -1), np.where(found, np.take_along_axis(blocks, iy[None], axis=0)[0], 2)


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
        self.stale_chunks: list[tuple[int, int]] = []
        self.worlds: dict[str, FakeWorld] = {"design": FakeWorld()}
        self.texts: dict[str, dict[str, Any]] = {}
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
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", 0, limit=64 << 20)
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
        done = job["total"] if settled else job["polls"] * job["total"] // max(job["steps"], 1)
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
        payload = encode_rle(world.blocks(box), world.palette, origin=box.min)
        payload["world"] = args["world"]
        return self._job("get_region", payload)

    def op_get_heightmap(self, args: dict[str, Any]) -> dict[str, Any]:
        world, box = self._world(args["world"]), self._bounds(args, Bounds2D)
        heights, top = world.heightmap(box)
        result = {**box.to_json(), "heights": heights.ravel().tolist(), "palette": world.palette}
        if not self.omit_top:
            result["top"] = top.ravel().tolist()
        return self._job("get_heightmap", result)

    def op_get_light(self, args: dict[str, Any]) -> dict[str, Any]:
        world, box = self._world(args["world"]), self._bounds(args, Bounds)
        palette, indices = np.unique(world.light(box), return_inverse=True)
        payload = encode_rle(indices.reshape(box.shape).astype(np.int16), palette.tolist(), origin=box.min)
        payload["world"] = args["world"]
        payload["chunks"] = [
            {"cx": cx, "cz": cz, "light": "stale" if (cx, cz) in self.stale_chunks else "fresh"}
            for cx in range(box.min[0] >> 4, (box.max[0] >> 4) + 1)
            for cz in range(box.min[2] >> 4, (box.max[2] >> 4) + 1)
        ]
        return self._job("get_light", payload)

    def op_set_blocks(self, args: dict[str, Any]) -> dict[str, Any]:
        world, blocks = self._world(args["world"]), args["blocks"]
        if len(blocks) > MAX_SET_BLOCKS:
            raise FakeOpError("TOO_MANY_BLOCKS", f"{len(blocks)} blocks over {MAX_SET_BLOCKS}")
        indices = [world.index_of(entry[3], f"blocks[{i}]") for i, entry in enumerate(blocks)]
        for (x, y, z, _), index in zip(blocks, indices):
            world.edits[(x, y, z)] = index
        return self._job("set_blocks", {"blocks": len(blocks)}, total=len(blocks))

    def op_fill(self, args: dict[str, Any]) -> dict[str, Any]:
        world, box = self._world(args["world"]), self._bounds(args, Bounds)
        index = world.index_of(args["block"])
        for pos in product(*(range(lo, hi + 1) for lo, hi in zip(box.min, box.max))):
            world.edits[pos] = index
        return self._job("fill", {"blocks": box.volume}, total=box.volume)

    def op_replace(self, args: dict[str, Any]) -> dict[str, Any]:
        world, box = self._world(args["world"]), self._bounds(args, Bounds)
        names = [args["from"]] if isinstance(args["from"], str) else list(args["from"])
        sources, target = [world.index_of(name) for name in names], world.index_of(args["to"])
        for iy, iz, ix in zip(*np.nonzero(np.isin(world.blocks(box), sources))):
            world.edits[(box.min[0] + int(ix), box.min[1] + int(iy), box.min[2] + int(iz))] = target
        return self._job("replace", {"blocks": box.volume}, total=box.volume)

    def op_list_entities(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        self._world(args["world"])
        return [{"id": 7, "type": "text", "save_id": "FloatingText", "pos": [0, 65, 0], "yaw": 0, "pitch": 0, "name_tag": "hi"}]

    def op_tail_log(self, args: dict[str, Any]) -> dict[str, Any]:
        lines = [f"[Server thread/INFO]: line {i}" for i in range(min(int(args.get("n", 50)), 1000))]
        return {"lines": lines, "bytes": sum(len(line) + 1 for line in lines)}

    def op_set_text(self, args: dict[str, Any]) -> dict[str, Any]:
        text_id = args.get("id") or f"t{len(self.texts) + 1}"
        self.texts[text_id] = {"world": args["world"], "pos": list(args["pos"]), "text": args["text"]}
        return {"id": text_id}

    def op_remove_text(self, args: dict[str, Any]) -> dict[str, Any]:
        if self.texts.pop(args["id"], None) is None:
            raise FakeOpError("ENTITY_NOT_FOUND", f"no text {args['id']!r}")
        return {}
