"""Read and index tools over stdio, each answering ``{"ok": ...}`` and never raising.

The bridge and the index are created on first use, so the server starts while the
design instance is down and ``server_status`` can say so. Bridge calls run on a
worker thread through ``_run``; a failed tool answers ``{"ok": False, "error", "code"}``.
"""

from __future__ import annotations

import functools
import logging
import threading
from collections.abc import Callable
from typing import Any

import anyio
import numpy as np
from mcp.server.fastmcp import FastMCP

from designer import config
from designer.bridge import Bridge, BridgeError
from designer.palettes import load_palettes
from designer.region import Bounds, Bounds2D, Heightmap, fetch_heightmap, fetch_region
from designer.render import Marker, ascii_heightmap, markers_from_index, summary, topdown_png
from designer.world_index import KINDS, Location, NamedRegion, WorldIndex, resolve_at

MAX_AREA, MAX_RADIUS, MAX_LOG_LINES = 256, 8, 200
# One glyph per ``BlockClass`` value: air, solid, liquid, passable, danger.
CLASS_GLYPHS = np.array(list(".#~,!"))
NOT_DESIGNER = "the bridge is not a designer instance: server_info.designer is false"

mcp = FastMCP("riftal-designer")
log = logging.getLogger("designer.mcp")
_bridge: Bridge | None = None
_index: WorldIndex | None = None
_lock = threading.Lock()

def bridge() -> Bridge:
    global _bridge
    with _lock:
        if _bridge is None:
            settings = config.load_settings()
            _bridge = Bridge(settings.host, settings.port, settings.token)
        return _bridge

def index() -> WorldIndex:
    global _index
    with _lock:
        if _index is None:
            _index = WorldIndex.load()
        return _index

def reset() -> None:
    global _bridge, _index
    with _lock:
        if _bridge is not None:
            _bridge.close()
        _bridge = _index = None

async def _run(fn: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    return await anyio.to_thread.run_sync(functools.partial(fn, *args, **kwargs))

def _error(exc: BaseException) -> dict[str, Any]:
    message = exc.args[0] if isinstance(exc, KeyError) and exc.args else str(exc)
    return {"ok": False, "error": str(message), "code": getattr(exc, "code", None)}

def _ensure_designer() -> dict[str, Any] | None:
    """``None`` when the bridge reports ``designer: true``, else the refusal every mutating tool answers with."""
    if bridge().is_designer():
        return None
    return {"ok": False, "error": NOT_DESIGNER, "code": "not_designer"}

def tool(fn: Callable[..., Any]) -> Callable[..., Any]:
    @functools.wraps(fn)
    async def wrapper(*args: Any, **kwargs: Any) -> dict[str, Any]:
        try:
            return {"ok": True, **await fn(*args, **kwargs)}
        except Exception as exc:
            return _error(exc)

    return mcp.tool()(wrapper)

def _area(at: str, size: int, world: str | None) -> tuple[Heightmap, list[Marker]]:
    size = min(int(size), MAX_AREA)
    world, (x, _, z) = resolve_at(index(), at, world)
    bounds = Bounds2D.from_center((x, z), (size, size))
    return fetch_heightmap(bridge(), world, bounds, need_top=True), markers_from_index(index(), world, bounds)

def _summary(hm: Heightmap) -> dict[str, Any]:
    return {**summary(hm), "size": "x".join(map(str, hm.bounds.size))}

def _status() -> dict[str, Any]:
    b = bridge()
    try:
        rtt = b.ping()
    except BridgeError as exc:
        return {"connected": False, "designer": False, "error": str(exc)}
    info = b.server_info(refresh=True)
    return {"connected": True, "rtt_ms": round(rtt * 1000, 1), "server_info": info, "designer": info.get("designer") is True, "worlds": b.call("list_worlds")}

def _inspect(at: str, radius: int, world: str | None) -> dict[str, Any]:
    radius = max(0, min(int(radius), MAX_RADIUS))
    world, (x, y, z) = resolve_at(index(), at, world)
    if y is None:
        y = fetch_heightmap(bridge(), world, Bounds2D((x, z), (x, z))).height(x, z)
        if y < 0:
            raise ValueError(f"column {x},{z} in {world} is empty; give x,y,z")
    region = fetch_region(bridge(), world, Bounds.from_center((x, y, z), (2 * radius + 1,) * 3))
    glyphs = CLASS_GLYPHS[region.classes()]
    slices = [{"y": region.bounds.min[1] + iy, "rows": ["".join(row) for row in layer]} for iy, layer in enumerate(glyphs)]
    return {"world": world, "center": [x, y, z], "bounds": region.bounds.to_json(), "counts": region.counts(), "slices": slices}

def _save(entry: Location | NamedRegion | None = None) -> dict[str, Any]:
    index().save()
    return {"entry": None if entry is None else entry.to_json()}

@tool
async def server_status() -> dict[str, Any]:
    """Whether the bridge answers, its round trip, ``server_info``, the designer flag and the worlds on disk."""
    return await _run(_status)

@tool
async def index_list(kind: str | None = None, tag: str | None = None) -> dict[str, Any]:
    """Entries of ``world_index.json``: ``kind`` is worlds, locations or regions; ``tag`` filters locations and regions."""
    if kind is not None and kind not in KINDS:
        raise ValueError(f"kind must be one of {', '.join(KINDS)}, not {kind!r}")
    idx = index()
    kinds = KINDS if kind is None else (kind,)
    out = {k: [e.to_json() for e in getattr(idx, k)] for k in kinds}
    if tag is not None:
        out = {k: [e for e in v if tag in e.get("tags", ())] for k, v in out.items() if k != "worlds"}
    return {"default_world": idx.default_world, **out}

@tool
async def index_resolve(name: str) -> dict[str, Any]:
    """The location or region called ``name`` and the position it stands for; a region resolves to its centre."""
    entry = index().resolve(name)
    return {"kind": type(entry).__name__.lower().removeprefix("named"), "entry": entry.to_json(), "pos": list(index().resolve_pos(name))}

@tool
async def heightmap_ascii(at: str, size: int = 64, world: str | None = None) -> dict[str, Any]:
    """An ASCII heightmap of a ``size`` square (at most 256) around ``at``: a name, ``x,z`` or ``x,y,z``."""
    hm, markers = await _run(_area, at, size, world)
    return {"text": ascii_heightmap(hm, markers), "summary": _summary(hm)}

@tool
async def render(at: str, kind: str = "topdown", size: int = 64, world: str | None = None) -> dict[str, Any]:
    """Write a PNG under ``reports/`` and return its path with a summary; ``kind`` is ``topdown``."""
    if kind != "topdown":
        raise ValueError(f"unknown render kind {kind!r}; only topdown exists")
    hm, markers = await _run(_area, at, size, world)
    path = await _run(topdown_png, hm, load_palettes()["colors"], markers)
    return {"path": str(path), "summary": _summary(hm)}

@tool
async def inspect(at: str, radius: int = 3, world: str | None = None) -> dict[str, Any]:
    """Block counts and one ASCII slice per y around ``at``, ``radius`` at most 8; glyphs ``. # ~ , !`` by class."""
    return await _run(_inspect, at, radius, world)

@tool
async def define_region(
    name: str, min: list[int], max: list[int], world: str, tags: list[str] | None = None, meta: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Add a named region to the index and save it; the name must be new and match ``[a-z0-9_]+``."""
    entry = index().add_region(NamedRegion(name, world, tuple(min), tuple(max), list(tags or []), dict(meta or {})))
    return await _run(_save, entry)

@tool
async def define_location(
    name: str, pos: list[int], world: str, yaw: float = 0, pitch: float = 0, tags: list[str] | None = None,
) -> dict[str, Any]:
    """Add a named location to the index and save it; ``pos`` is the feet block."""
    entry = index().add_location(Location(name, world, tuple(pos), yaw, pitch, list(tags or [])))
    return await _run(_save, entry)

@tool
async def index_remove(name: str) -> dict[str, Any]:
    """Remove a location or region from the index and save it."""
    return await _run(_save, index().remove(name))

@tool
async def list_entities(world: str) -> dict[str, Any]:
    """Entities in ``world`` as the bridge reports them, players excluded."""
    entities = await _run(bridge().call, "list_entities", world=world)
    return {"world": world, "count": len(entities), "entities": entities}

@tool
async def tail_log(lines: int = 50) -> dict[str, Any]:
    """The last ``lines`` (at most 200) of the server log, colour codes stripped."""
    return await _run(bridge().call, "tail_log", n=max(1, min(int(lines), MAX_LOG_LINES)))

def main() -> None:
    try:
        refused = _ensure_designer()
    except Exception as exc:
        log.warning("bridge unavailable at start: %s", exc)
    else:
        if refused is not None:
            log.warning("%s; mutating tools will be refused", refused["error"])
    mcp.run(transport="stdio")

if __name__ == "__main__":
    main()
