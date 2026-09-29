"""Region snapshots on disk, the diff between two, restore, and the persisted undo manifest."""

from __future__ import annotations

import json
import os
import re
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import numpy as np

from designer import __version__, config
from designer.blocks import RLE_ORDER
from designer.bridge import Bridge, BridgeError
from designer.edits import DEFAULT_BATCH, ApplyResult, EditList, Fill, Op, SetBlock
from designer.region import Bounds, Region, fetch_region

TS_FORMAT = "%Y%m%dT%H%M%S.%fZ"
LABEL_RE = re.compile(r"[a-z0-9_-]+")
MANIFEST_NAME = "undo-manifest.json"


@dataclass(eq=False)
class Snapshot:
    path: Path
    world: str
    bounds: Bounds
    label: str
    timestamp: str
    region: Region


@dataclass
class Diff:
    changed: int
    bbox: Bounds | None
    by_type: dict[str, dict[str, int]]


def save(region: Region, label: str, *, ts: datetime | None = None) -> Path:
    """Write ``region`` under ``SNAPSHOTS_DIR/<world>/<ts>-<label>.npz``; ``ts`` defaults to now, UTC."""
    for name, value in (("world", region.world), ("label", label)):
        if not LABEL_RE.fullmatch(value):
            raise ValueError(f"{name} must match {LABEL_RE.pattern!r}, got {value!r}")
    stamp = (ts or datetime.now(UTC)).strftime(TS_FORMAT)
    meta = {"world": region.world, "timestamp": stamp, "label": label, "toolkit": __version__, "order": "".join(RLE_ORDER)}
    path = config.SNAPSHOTS_DIR / region.world / f"{stamp}-{label}.npz"
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        path, blocks=region.blocks, palette=np.array(region.palette, dtype=np.str_),
        bmin=np.array(region.bounds.min), bmax=np.array(region.bounds.max), meta=json.dumps(meta),
    )
    return path


def load(path: Path) -> Snapshot:
    with np.load(path) as data:
        meta = json.loads(data["meta"].item())
        if meta.get("order") != "".join(RLE_ORDER):
            raise ValueError(f"{path} was written in order {meta.get('order')!r}, expected {''.join(RLE_ORDER)!r}")
        bounds = Bounds(tuple(data["bmin"].tolist()), tuple(data["bmax"].tolist()))
        region = Region(meta["world"], bounds, np.ascontiguousarray(data["blocks"], dtype=np.int16), data["palette"].tolist())
    return Snapshot(Path(path), meta["world"], bounds, meta["label"], meta["timestamp"], region)


def take(bridge: Bridge, world: str, bounds: Bounds, label: str) -> Snapshot:
    """Fetch ``bounds`` and save it; the result is read back from disk so a bad write fails here."""
    return load(save(fetch_region(bridge, world, bounds), label))


def _region(source: Snapshot | Region) -> Region:
    return source.region if isinstance(source, Snapshot) else source


def _remap(a: Region, b: Region) -> tuple[list[str], np.ndarray]:
    """``b.blocks`` over ``a``'s palette extended by any name only ``b`` uses."""
    if (a.world, a.bounds) != (b.world, b.bounds):
        raise ValueError(f"cannot compare {a.world!r} {a.bounds.min}..{a.bounds.max} with {b.world!r} {b.bounds.min}..{b.bounds.max}")
    index = {name: i for i, name in enumerate(a.palette)}
    lut = np.array([index.setdefault(name, len(index)) for name in b.palette], dtype=np.int16)
    return list(index), lut[b.blocks]


def diff(a: Snapshot | Region, b: Snapshot | Region) -> Diff:
    """Cells where ``b`` differs from ``a``, with per-name counts of what ``a`` lost and ``b`` gained."""
    a, b = _region(a), _region(b)
    palette, after = _remap(a, b)
    mask = a.blocks != after
    if not mask.any():
        return Diff(0, None, {})
    iy, iz, ix = np.nonzero(mask)
    x0, y0, z0 = a.bounds.min
    bbox = Bounds((x0 + ix.min(), y0 + iy.min(), z0 + iz.min()), (x0 + ix.max(), y0 + iy.max(), z0 + iz.max()))
    removed = np.bincount(a.blocks[mask], minlength=len(palette))
    added = np.bincount(after[mask], minlength=len(palette))
    by_type = {name: {"removed": int(r), "added": int(g)} for name, r, g in zip(palette, removed, added) if r or g}
    return Diff(int(mask.sum()), bbox, by_type)


def _restore_ops(target: Region, mask: np.ndarray, batch: int) -> list[Op]:
    """The ops that repaint every ``True`` cell of ``mask`` back to ``target``.

    Runs of equal value along x are found in numpy: a sentinel marks the cells
    ``mask`` excludes, a boolean diff finds where each run starts, and the run
    lengths come from the gaps between starts. That is one pass over the array
    regardless of how many runs it holds, rather than a Python loop building one
    ``SetBlock`` per changed cell before anything is coalesced, which is two
    million iterations for a fully changed 128^3 region. A run becomes a
    ``Fill`` only once it is longer than ``batch``: shorter than that, its cells
    ride in the same shared ``set_blocks`` request as every other row's, for
    free, while a ``Fill`` always costs one request of its own however short the
    run, however many other rows are waiting in the same batch.
    """
    ny, nz, nx = mask.shape
    x0, y0, z0 = target.bounds.min
    coded = np.where(mask, target.blocks.astype(np.int32), np.int32(-1)).reshape(-1, nx)
    starts_here = np.ones_like(coded, dtype=bool)
    if nx > 1:
        starts_here[:, 1:] = coded[:, 1:] != coded[:, :-1]
    flat, starts = coded.ravel(), np.flatnonzero(starts_here.ravel())
    lengths, values = np.append(starts[1:], flat.size) - starts, flat[starts]
    rows, x_local = np.divmod(starts, nx)
    iy, iz = np.divmod(rows, nz)
    ops: list[Op] = []
    for y, z, x, length, value in zip(iy.tolist(), iz.tolist(), x_local.tolist(), lengths.tolist(), values.tolist()):
        if value < 0:
            continue
        block = target.palette[value]
        if length > batch:
            ops.append(Fill(Bounds((x0 + x, y0 + y, z0 + z), (x0 + x + length - 1, y0 + y, z0 + z)), block))
        else:
            ops.extend(SetBlock(x0 + x + i, y0 + y, z0 + z, block) for i in range(length))
    return ops


def restore(
    bridge: Bridge, snap: Snapshot, *, only_changed: bool = True, dry_run: bool = False, batch: int = DEFAULT_BATCH,
) -> ApplyResult:
    """Put the snapshot back; the state it overwrites is itself snapshotted as ``restore`` first."""
    target = snap.region
    if only_changed:
        _, now = _remap(target, fetch_region(bridge, snap.world, snap.bounds))
        mask = target.blocks != now
    else:
        mask = np.ones(target.blocks.shape, dtype=bool)
    edits = EditList(snap.world, _restore_ops(target, mask, batch), {"restore": str(snap.path)})
    return edits.apply(bridge, dry_run=dry_run, batch=batch, before=lambda world, bounds: take(bridge, world, bounds, "restore"))


def remove_texts(bridge: Bridge, ids: list[str], *, dry_run: bool = False) -> ApplyResult:
    """Remove each floating text in ``ids``, stopping at the first failure.

    A text the bridge no longer has counts as removed, so an undo that stopped
    partway, or one whose text was removed by hand, can still be completed.
    """
    result = ApplyResult(True)
    for text_id in [] if dry_run else ids:
        try:
            status = {"op": "remove_text", "state": "done", "result": bridge.call("remove_text", id=text_id)}
        except BridgeError as exc:
            if getattr(exc, "code", None) != "ENTITY_NOT_FOUND":
                result.ok = False
                result.errors.append(exc)
                return result
            status = {"op": "remove_text", "state": "done", "result": None}
        result.jobs.append(status)
    return result


class UndoStack:
    """Undo entries in a JSON manifest, rewritten whole on every change so a crash leaves the old file or the new one.

    ``session`` is a label: it is written on every entry this stack pushes and is what ``entries(session=...)``
    filters on. ``undo`` ignores it and walks every session's entries newest first, so the edits of a session that
    crashed are reversed from the next one. Each undo pushes the ``restore`` snapshot it took as an ``op="undo"``
    entry, which ``undo`` skips unless ``include_undo`` is set, so two undos reverse two edits rather than toggling
    one, and undoing an undo is asked for by name. Push is read-modify-write with ids from ``max + 1``, so the
    manifest assumes one writer at a time.

    An entry from ``push_texts`` has no snapshot: its ``path`` and ``bounds`` are ``None`` and its ``texts`` are
    the floating text ids it set, which its undo removes. That undo overwrites no block, so it pushes no entry.
    """

    def __init__(self, manifest: Path | None = None, session: str | None = None) -> None:
        self.manifest = config.SNAPSHOTS_DIR / MANIFEST_NAME if manifest is None else manifest
        self.session = session

    def entries(self, session: str | None = None) -> list[dict[str, Any]]:
        if not self.manifest.is_file():
            return []
        entries = json.loads(self.manifest.read_text(encoding="utf-8"))["entries"]
        return entries if session is None else [e for e in entries if e["session"] == session]

    def _write(self, entries: list[dict[str, Any]]) -> None:
        self.manifest.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.manifest.with_name(self.manifest.name + ".tmp")
        tmp.write_text(json.dumps({"version": 1, "entries": entries}, indent=1), encoding="utf-8", newline="\n")
        os.replace(tmp, self.manifest)

    def _add(self, entries: list[dict[str, Any]], fields: dict[str, Any]) -> int:
        entry_id = max((e["id"] for e in entries), default=0) + 1
        entries.append({"id": entry_id, "session": self.session, **fields, "restored": False})
        return entry_id

    def _append(self, entries: list[dict[str, Any]], snap: Snapshot, op: str) -> int:
        return self._add(entries, {
            "op": op, "world": snap.world, "bounds": snap.bounds.to_json(),
            "label": snap.label, "timestamp": snap.timestamp, "path": str(snap.path),
        })

    def push(self, snap: Snapshot, op: str) -> int:
        entries = self.entries()
        entry_id = self._append(entries, snap, op)
        self._write(entries)
        return entry_id

    def push_texts(self, world: str, ids: list[str], op: str) -> int:
        entries = self.entries()
        entry_id = self._add(entries, {
            "op": op, "world": world, "bounds": None, "label": op,
            "timestamp": datetime.now(UTC).strftime(TS_FORMAT), "path": None, "texts": list(ids),
        })
        self._write(entries)
        return entry_id

    def undo(self, bridge: Bridge, n: int = 1, *, dry_run: bool = False, include_undo: bool = False) -> list[ApplyResult]:
        """Restore the ``n`` newest entries not yet restored, newest first, stopping at the first failure."""
        entries, results = self.entries(), []
        pending = [e for e in reversed(entries) if not e["restored"] and (include_undo or e["op"] != "undo")]
        for entry in pending[:n]:
            if entry["path"] is None:
                result = remove_texts(bridge, entry["texts"], dry_run=dry_run)
            else:
                result = restore(bridge, load(Path(entry["path"])), dry_run=dry_run)
            results.append(result)
            if not result.ok:
                break
            if not dry_run:
                entry["restored"] = True
                if result.before_result is not None:
                    self._append(entries, result.before_result, "undo")
                self._write(entries)
        return results

    def prune(self, keep_days: int = 14, *, dry_run: bool = True) -> list[Path]:
        """Snapshots older than ``keep_days``; with ``dry_run`` off they and their entries are deleted.

        Every path is resolved against ``SNAPSHOTS_DIR`` and refused if it lands
        outside it, checked for every entry before anything is unlinked, so a
        manifest hand-edited or corrupted to name a path elsewhere never reaches
        ``unlink`` and never deletes part of the batch before the refusal.
        """
        cutoff = datetime.now(UTC) - timedelta(days=keep_days)
        entries = self.entries()
        old = [e for e in entries if datetime.strptime(e["timestamp"], TS_FORMAT).replace(tzinfo=UTC) < cutoff]
        paths = [e["path"] for e in old if e["path"] is not None]
        if old and not dry_run:
            root = config.SNAPSHOTS_DIR.resolve()
            resolved = []
            for name in paths:
                path = Path(name).resolve()
                if not path.is_relative_to(root):
                    raise ValueError(f"{name!r} resolves outside the snapshots directory {root}")
                resolved.append(path)
            for path in resolved:
                path.unlink(missing_ok=True)
            self._write([e for e in entries if e not in old])
        return [Path(name) for name in paths]


@dataclass
class Undoable:
    """What ``apply_undoable`` sent, with the snapshot path and undo id that reverse it, either ``None`` when nothing was pushed."""

    result: ApplyResult
    snapshot: str | None = None
    undo_id: int | None = None


def apply_undoable(
    bridge: Bridge, edits: EditList, op: str, session: str, *, dry_run: bool = False,
    on_progress: Callable[[int, int], None] | None = None,
) -> Undoable:
    """Send ``edits`` with an undo entry labelled ``op``, refusing an empty list.

    When a block is touched, the snapshot is taken and its undo entry pushed inside ``before``, ahead of the
    first request. Floating text alone leaves nothing to snapshot, so its entry is pushed once the texts are
    set, naming the ids the bridge answered, even when a later text failed.
    """
    if not edits.ops:
        raise ValueError("nothing to do: the edit list is empty")
    stack = UndoStack(session=session)
    done = Undoable(ApplyResult(True))

    def before(world: str, bounds: Bounds) -> Snapshot:
        snap = take(bridge, world, bounds, op)
        done.snapshot, done.undo_id = str(snap.path), stack.push(snap, op)
        return snap

    done.result = edits.apply(bridge, dry_run=dry_run, on_progress=on_progress, before=before)
    texts = [job["result"]["id"] for job in done.result.jobs if job["op"] == "set_text"]
    if edits.bounds is None and texts:
        done.undo_id = stack.push_texts(edits.world, texts, op)
    return done
