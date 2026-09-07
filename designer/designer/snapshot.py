"""Region snapshots on disk, the diff between two, restore, and the persisted undo manifest."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import numpy as np

from designer import __version__, config
from designer.blocks import RLE_ORDER
from designer.bridge import Bridge
from designer.edits import DEFAULT_BATCH, ApplyResult, EditList, SetBlock
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
    if not LABEL_RE.fullmatch(label):
        raise ValueError(f"label must match {LABEL_RE.pattern!r}, got {label!r}")
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
    x0, y0, z0 = snap.bounds.min
    ops = [SetBlock(x0 + ix, y0 + iy, z0 + iz, target.palette[target.blocks[iy, iz, ix]]) for iy, iz, ix in zip(*np.nonzero(mask))]
    edits = EditList(snap.world, ops, {"restore": str(snap.path)}).coalesce()
    return edits.apply(bridge, dry_run=dry_run, batch=batch, before=lambda world, bounds: take(bridge, world, bounds, "restore"))


class UndoStack:
    """Undo entries in a JSON manifest, rewritten whole on every change so a crash leaves the old file or the new one."""

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
        tmp.write_text(json.dumps({"version": 1, "entries": entries}, indent=1), encoding="utf-8")
        os.replace(tmp, self.manifest)

    def push(self, snap: Snapshot, op: str) -> int:
        entries = self.entries()
        entry_id = max((e["id"] for e in entries), default=0) + 1
        entries.append({
            "id": entry_id, "session": self.session, "op": op, "world": snap.world, "bounds": snap.bounds.to_json(),
            "label": snap.label, "timestamp": snap.timestamp, "path": str(snap.path), "restored": False,
        })
        self._write(entries)
        return entry_id

    def undo(self, bridge: Bridge, n: int = 1, *, dry_run: bool = False) -> list[ApplyResult]:
        """Restore the ``n`` newest entries not yet restored, newest first, stopping at the first failure."""
        entries, results = self.entries(), []
        for entry in [e for e in reversed(entries) if not e["restored"]][:n]:
            result = restore(bridge, load(Path(entry["path"])), dry_run=dry_run)
            results.append(result)
            if not result.ok:
                break
            if not dry_run:
                entry["restored"] = True
                self._write(entries)
        return results

    def prune(self, keep_days: int = 14, *, dry_run: bool = True) -> list[Path]:
        """Snapshots older than ``keep_days``; with ``dry_run`` off they and their entries are deleted."""
        cutoff = datetime.now(UTC) - timedelta(days=keep_days)
        entries = self.entries()
        old = [e for e in entries if datetime.strptime(e["timestamp"], TS_FORMAT).replace(tzinfo=UTC) < cutoff]
        if old and not dry_run:
            for entry in old:
                Path(entry["path"]).unlink(missing_ok=True)
            self._write([e for e in entries if e not in old])
        return [Path(e["path"]) for e in old]
