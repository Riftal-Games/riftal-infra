"""Markers proving a block survives the container being replaced on the same volume.

``persist_mark`` writes one entry per marker name: the world, position and block it
placed. ``persist_verify`` reads it back, which must work from a process that started
after the container was rebuilt, so the manifest lives on disk rather than in the MCP
server's memory. The file is written to a temp path and moved over the old one, same
as the undo manifest in ``snapshot.py``, so a crash mid-write leaves the previous file.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from designer import config

MANIFEST_NAME = "persist-markers.json"


def manifest_path() -> Path:
    return config.REPORTS_DIR / MANIFEST_NAME


def load() -> dict[str, dict[str, Any]]:
    path = manifest_path()
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}


def save(entries: dict[str, dict[str, Any]]) -> None:
    path = manifest_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(entries, indent=1, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    os.replace(tmp, path)


def record(marker: str, world: str, pos: tuple[int, int, int], block: str) -> None:
    entries = load()
    entries[marker] = {"world": world, "pos": list(pos), "block": block}
    save(entries)


def get(marker: str) -> dict[str, Any]:
    entries = load()
    if marker not in entries:
        raise KeyError(f"no persist_mark recorded as {marker!r}")
    return entries[marker]
