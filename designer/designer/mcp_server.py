"""Read, index and mutating tools over stdio, each answering ``{"ok": ...}`` and never raising.

The bridge and the index are created on first use, so the server starts while the
design instance is down and ``server_status`` can say so. Bridge calls run on a
worker thread through ``_run``; a failed tool answers ``{"ok": False, "error", "code"}``.
A ``mutating`` tool is refused under ``DESIGNER_READ_ONLY=1`` and unless the bridge
is a designer instance; one that writes blocks snapshots its bounds and pushes the
undo entry before the first request goes out.
"""

from __future__ import annotations

import functools
import logging
import os
import threading
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import anyio
import numpy as np
from mcp.server.fastmcp import Context, FastMCP

from designer import config
from designer import snapshot as snapshots
from designer.bridge import Bridge, BridgeError
from designer.edits import ApplyResult, EditList, Fill, Replace, SetBlock
from designer.palettes import load_palettes
from designer.region import Bounds, Bounds2D, Heightmap, fetch_heightmap, fetch_region
from designer.render import Marker, ascii_heightmap, markers_from_index, summary, topdown_png
from designer.snapshot import Snapshot, UndoStack
from designer.world_index import KINDS, Location, NamedRegion, WorldIndex, resolve_at

MAX_AREA, MAX_RADIUS, MAX_LOG_LINES, MAX_BLOCKS_PER_CALL = 256, 8, 200, 4096
# One glyph per ``BlockClass`` value: air, solid, liquid, passable, danger.
CLASS_GLYPHS = np.array(list(".#~,!"))
NOT_DESIGNER = "the bridge is not a designer instance: server_info.designer is false"
READ_ONLY = "DESIGNER_READ_ONLY=1 is set: mutating tools are disabled for this session"
SESSION = datetime.now(UTC).strftime("mcp-%Y%m%dT%H%M%SZ")

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
    if kind == "worlds" and tag is not None:
        raise ValueError("worlds carry no tags; drop the tag or ask for locations or regions")
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

def _read_only() -> dict[str, Any] | None:
    if os.environ.get("DESIGNER_READ_ONLY") == "1":
        return {"ok": False, "error": READ_ONLY, "code": "read_only"}
    return None

def mutating(fn: Callable[..., dict[str, Any]]) -> Callable[..., Any]:
    """A sync tool that runs on the worker thread once the read-only switch and the designer gate both pass."""
    @functools.wraps(fn)
    async def wrapper(*args: Any, **kwargs: Any) -> dict[str, Any]:
        refused = _read_only() or await _run(_ensure_designer)
        return refused if refused is not None else await _run(fn, *args, **kwargs)

    return tool(wrapper)

def _target(target: str | dict[str, Any], world: str | None) -> tuple[str, Bounds]:
    """A region name from the index or a ``{"min", "max"}`` dict; ``world`` defaults to the region's, else the index default."""
    if isinstance(target, str):
        entry = index().resolve(target)
        if not isinstance(entry, NamedRegion):
            raise ValueError(f"{target!r} is a location; a target is a region name or a min/max dict")
        return world or entry.world, entry.bounds
    return world or index().default_world, Bounds.from_json(target)

def _progress(ctx: Context | None) -> Callable[[int, int], None] | None:
    """Job progress forwarded to the client from the worker thread, or ``None`` when no request is being served."""
    if ctx is None:
        return None
    try:
        ctx.request_context
    except ValueError:
        return None
    return lambda done, total: anyio.from_thread.run(ctx.report_progress, done, total)

def _finish(out: dict[str, Any], result: ApplyResult) -> dict[str, Any]:
    """The first ``BridgeError`` folded into the answer when the run stopped early, so the undo entry is still reported."""
    out["jobs"] = result.jobs
    return out if result.ok else {**out, **_error(result.errors[0])}

def _apply(edits: EditList, op: str, dry_run: bool, ctx: Context | None) -> dict[str, Any]:
    """Send ``edits``; the snapshot is taken and its undo entry pushed inside ``before``, ahead of the first request."""
    if edits.bounds is None:
        raise ValueError("nothing to do: no block is touched")
    out: dict[str, Any] = {
        "world": edits.world, "bounds": edits.bounds.to_json(), "dry_run": dry_run,
        "blocks": edits.count_blocks(), "requests": len(edits.requests()), "snapshot": None, "undo_id": None,
    }

    def before(world: str, bounds: Bounds) -> Snapshot:
        snap = snapshots.take(bridge(), world, bounds, op)
        out["snapshot"], out["undo_id"] = str(snap.path), UndoStack(session=SESSION).push(snap, op)
        return snap

    result = edits.apply(bridge(), dry_run=dry_run, on_progress=_progress(ctx), before=before)
    if not dry_run:
        out["blocks"] = result.blocks
    return _finish(out, result)

def _snapshot_path(ref: str | int) -> Path:
    """A manifest id, or a path that must resolve under ``SNAPSHOTS_DIR``; a relative path is rooted there, not at the cwd."""
    if isinstance(ref, int) or ref.isdigit():
        for entry in UndoStack().entries():
            if entry["id"] == int(ref):
                return Path(entry["path"])
        raise KeyError(f"no undo entry with id {ref}")
    root = config.SNAPSHOTS_DIR.resolve()
    path = (root / ref).resolve()
    if not path.is_relative_to(root):
        raise ValueError(f"{ref!r} resolves outside the snapshots directory {root}")
    return path

def _entry_id(path: Path) -> int | None:
    ids = [e["id"] for e in UndoStack().entries() if e["path"] == str(path)]
    return ids[-1] if ids else None

@mutating
def fill(target: str | dict[str, Any], block: str, world: str | None = None, dry_run: bool = False, ctx: Context | None = None) -> dict[str, Any]:
    """Fill ``target``, a region name or ``{"min", "max"}``, with ``block``; snapshots first and answers with the undo id."""
    world, bounds = _target(target, world)
    return _apply(EditList(world, [Fill(bounds, block)]), "fill", dry_run, ctx)

@mutating
def replace(
    target: str | dict[str, Any], from_block: str | list[str], to_block: str, world: str | None = None, dry_run: bool = False, ctx: Context | None = None,
) -> dict[str, Any]:
    """Turn every ``from_block`` inside ``target`` into ``to_block``; snapshots first and answers with the undo id."""
    world, bounds = _target(target, world)
    return _apply(EditList(world, [Replace(bounds, from_block, to_block)]), "replace", dry_run, ctx)

@mutating
def set_blocks(blocks: list[list[Any]], world: str | None = None, dry_run: bool = False, ctx: Context | None = None) -> dict[str, Any]:
    """Set up to 4096 ``[x, y, z, block]`` entries; runs of eight or more along x go as fills. Snapshots the bounding box first."""
    if not 1 <= len(blocks) <= MAX_BLOCKS_PER_CALL:
        raise ValueError(f"set_blocks takes 1 to {MAX_BLOCKS_PER_CALL} entries per call, got {len(blocks)}")
    edits = EditList(world or index().default_world, [SetBlock(*entry) for entry in blocks]).coalesce()
    return _apply(edits, "set_blocks", dry_run, ctx)

@mutating
def snapshot(target: str | dict[str, Any], label: str, world: str | None = None) -> dict[str, Any]:
    """Save ``target`` to disk as ``label`` without an undo entry; ``restore`` takes the path back."""
    world, bounds = _target(target, world)
    snap = snapshots.take(bridge(), world, bounds, label)
    return {"world": snap.world, "bounds": snap.bounds.to_json(), "label": snap.label, "timestamp": snap.timestamp, "path": str(snap.path)}

@mutating
def restore(snapshot: str | int, dry_run: bool = False) -> dict[str, Any]:
    """Put a snapshot back by path or undo id, sending only the cells that differ; what it overwrites is pushed as a ``restore`` entry."""
    snap = snapshots.load(_snapshot_path(snapshot))
    result = snapshots.restore(bridge(), snap, dry_run=dry_run)
    out: dict[str, Any] = {
        "world": snap.world, "bounds": snap.bounds.to_json(), "restored": str(snap.path), "dry_run": dry_run,
        "blocks": result.blocks, "snapshot": None, "undo_id": None,
    }
    if result.before_result is not None:
        out["snapshot"], out["undo_id"] = str(result.before_result.path), UndoStack(session=SESSION).push(result.before_result, "restore")
    return _finish(out, result)

@mutating
def undo(n: int = 1, dry_run: bool = False) -> dict[str, Any]:
    """Reverse the ``n`` newest edits not yet undone, from any session; each pushes an ``undo`` entry that plain ``undo`` skips."""
    stack = UndoStack(session=SESSION)
    done_before = {e["id"] for e in stack.entries() if e["restored"]}
    results = stack.undo(bridge(), max(1, int(n)), dry_run=dry_run)
    undone = [e["id"] for e in stack.entries() if e["restored"] and e["id"] not in done_before]
    out: dict[str, Any] = {
        "dry_run": dry_run, "count": len(results), "undone": sorted(undone, reverse=True), "blocks": sum(r.blocks for r in results),
        "snapshot": None, "undo_id": None, "jobs": [job for r in results for job in r.jobs],
    }
    last = results[-1].before_result if results else None
    if last is not None:
        out["snapshot"], out["undo_id"] = str(last.path), _entry_id(last.path)
    failed = [r for r in results if not r.ok]
    return {**out, **_error(failed[0].errors[0])} if failed else out

@tool
async def list_snapshots(world: str | None = None, limit: int = 20) -> dict[str, Any]:
    """Snapshot files on disk, newest first, with the undo id of any that the manifest knows."""
    if (refused := _read_only()) is not None:
        return refused
    if world is not None and not snapshots.LABEL_RE.fullmatch(world):
        raise ValueError(f"world must match {snapshots.LABEL_RE.pattern!r}, got {world!r}")
    ids = {e["path"]: e["id"] for e in UndoStack().entries()}
    files = sorted(config.SNAPSHOTS_DIR.glob(f"{world or '*'}/*.npz"), key=lambda p: p.name, reverse=True)[: max(1, int(limit))]
    return {"snapshots": [
        {"path": str(p), "world": p.parent.name, "timestamp": p.stem.partition("-")[0], "label": p.stem.partition("-")[2], "bytes": p.stat().st_size, "undo_id": ids.get(str(p))}
        for p in files
    ]}

@tool
async def list_undo(limit: int = 20) -> dict[str, Any]:
    """Undo manifest entries newest first: id, session, op, world, bounds, label, timestamp, path, restored."""
    if (refused := _read_only()) is not None:
        return refused
    entries = UndoStack().entries()
    return {"manifest": str(UndoStack().manifest), "total": len(entries), "entries": entries[::-1][: max(1, int(limit))]}

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
