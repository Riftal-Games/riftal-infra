"""Text rendering of a heightmap, plus the marker and report-path helpers every render shares."""

from __future__ import annotations

import math
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np

from designer.blocks import BlockClass, class_lut
from designer.config import REPORTS_DIR
from designer.region import Bounds2D, Heightmap
from designer.world_index import WorldIndex

# Low to high. Space is reserved for an empty column and ``~`` for liquid.
RAMP = ".,:-=+*#%@"
LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
# Chunk edges, so a tick on the map is a boundary a player can also see.
TICK = 16


@dataclass(frozen=True)
class Marker:
    label: str
    x: int
    z: int
    y: int
    kind: str = "location"


def markers_from_index(index: WorldIndex, world: str, bounds: Bounds2D) -> list[Marker]:
    """Locations inside ``bounds`` in index order, then each region corner inside it as a ``corner``."""
    markers = [
        Marker(l.name, l.pos[0], l.pos[2], l.pos[1])
        for l in index.locations
        if l.world == world and bounds.contains((l.pos[0], l.pos[2]))
    ]
    for region in (r for r in index.regions if r.world == world):
        for x in (region.min[0], region.max[0]):
            for z in (region.min[2], region.max[2]):
                if bounds.contains((x, z)):
                    markers.append(Marker(region.name, x, z, region.min[1], "corner"))
    return markers


def report_path(kind: str, world: str, bounds: Bounds2D, ext: str, ts: datetime | None = None) -> Path:
    ts = datetime.now() if ts is None else ts
    sx, sz = bounds.size
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    return REPORTS_DIR / f"{kind}-{world}-{bounds.min[0]}_{bounds.min[1]}-{sx}x{sz}-{ts:%Y%m%d-%H%M%S}.{ext}"


def _liquid(hm: Heightmap) -> np.ndarray:
    if hm.top is None:
        return np.zeros(hm.heights.shape, dtype=bool)
    return class_lut(hm.palette)[hm.top] == BlockClass.LIQUID


def summary(hm: Heightmap) -> dict[str, Any]:
    """Height range and mean over non-empty columns; ``flat`` is the share of them at the modal height."""
    valid = hm.heights >= 0
    out: dict[str, Any] = {"size": hm.bounds.size, "columns": int(valid.sum())}
    out.update(min=None, max=None, mean=None, water=None, flat=None)
    if valid.any():
        heights = hm.heights[valid]
        out.update(min=int(heights.min()), max=int(heights.max()), mean=float(heights.mean()))
        out["flat"] = float(np.bincount(heights).max() / heights.size)
        if hm.top is not None:
            out["water"] = float(_liquid(hm)[valid].mean())
    return out


def _pool(values: np.ndarray, valid: np.ndarray, step: int) -> tuple[np.ndarray, np.ndarray]:
    """Mean of ``values`` over each ``step`` square of valid cells, and whether the square had any."""
    pad = ((0, -valid.shape[0] % step), (0, -valid.shape[1] % step))
    total = np.pad(np.where(valid, values, 0).astype(float), pad)
    count = np.pad(valid, pad).astype(float)
    shape = (total.shape[0] // step, step, total.shape[1] // step, step)
    total, count = total.reshape(shape).sum(axis=(1, 3)), count.reshape(shape).sum(axis=(1, 3))
    return np.divide(total, count, out=np.zeros_like(total), where=count > 0), count > 0


def _ticks(lo: int, hi: int, step: int) -> dict[int, str]:
    return {(v - lo) // step: str(v) for v in range(-(-lo // TICK) * TICK, hi + 1, TICK)}


def ascii_heightmap(
    hm: Heightmap, markers: Iterable[Marker] = (), *, max_width: int = 128, band: int | None = None, legend: bool = True
) -> str:
    if max_width < 1 or (band is not None and band < 1):
        raise ValueError(f"max_width and band must be at least 1, got {max_width} and {band}")
    (xmin, zmin), (xmax, zmax) = hm.bounds.min, hm.bounds.max
    step = max(1, math.ceil(hm.bounds.size[0] / max_width))
    valid = hm.heights >= 0
    heights, filled = _pool(hm.heights, valid, step)
    liquid, _ = _pool(_liquid(hm), valid, step)
    stats = summary(hm)
    lo, hi = (0, 0) if stats["min"] is None else (stats["min"], stats["max"])
    if band is None:
        band = max(1, math.ceil((hi - lo + 1) / len(RAMP)))
    level = np.clip((heights - lo) // band, 0, len(RAMP) - 1).astype(int)
    grid = np.where(filled, np.where(liquid >= 0.5, "~", np.array(list(RAMP))[level]), " ")

    lettered: list[tuple[str, Marker]] = []
    corners: dict[str, list[tuple[int, int]]] = {}
    for marker in markers:
        if not hm.bounds.contains((marker.x, marker.z)):
            continue
        if marker.kind == "corner":
            glyph = "+"
            corners.setdefault(marker.label, []).append((marker.x, marker.z))
        else:
            glyph = LETTERS[len(lettered)] if len(lettered) < len(LETTERS) else "?"
            lettered.append((glyph, marker))
        grid[(marker.z - zmin) // step, (marker.x - xmin) // step] = glyph

    z_ticks, x_ticks = _ticks(zmin, zmax, step), _ticks(xmin, xmax, step)
    gutter = max((len(s) for s in z_ticks.values()), default=0) + 1
    top = [" "] * (gutter + grid.shape[1])
    for ix, label in x_ticks.items():
        at, end = gutter + ix, gutter + ix + len(label)
        if end <= len(top) and all(c == " " for c in top[at - 1 : end]):
            top[at:end] = label
    y_range = "empty" if stats["min"] is None else f"{lo}..{hi}"
    lines = [
        f"world={hm.world} x={xmin}..{xmax} z={zmin}..{zmax} y={y_range} band={band} step={step}",
        "".join(top).rstrip(),
    ]
    lines += [z_ticks.get(iz, "").rjust(gutter - 1) + " " + "".join(row) for iz, row in enumerate(grid)]
    if legend:
        lines += [f"{glyph} {m.label} ({m.x},{m.y},{m.z})" for glyph, m in lettered]
        for name, points in corners.items():
            xs, zs = [p[0] for p in points], [p[1] for p in points]
            lines.append(f"+ {name} ({min(xs)},{min(zs)})..({max(xs)},{max(zs)})")
        lines.append(f"ramp {RAMP[0]} y<{lo + band} to {RAMP[-1]} y>={lo + (len(RAMP) - 1) * band}, ~ liquid, space empty")
    return "\n".join(lines)
