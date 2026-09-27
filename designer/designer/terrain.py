"""Height and slope stats, flat-site search, and terraform. Pure over a ``Heightmap``; ``terraform`` returns an ``EditList``."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

from designer.blocks import AIR, BlockClass, class_lut
from designer.edits import EditList, Fill
from designer.region import Bounds, Bounds2D, Heightmap

MODES = ("flatten", "raise", "lower", "smooth")

# The four in-map neighbours a slope or a smoothing blur reads, as ``(dz, dx)``.
NEIGHBORS4 = ((0, 1), (0, -1), (1, 0), (-1, 0))


def _liquid(hm: Heightmap) -> np.ndarray:
    """Bool per column: the top block is a liquid. Every column is ``False`` when the heightmap carries no top."""
    if hm.top is None:
        return np.zeros(hm.heights.shape, dtype=bool)
    return class_lut(hm.palette)[hm.top] == BlockClass.LIQUID


def _shift(a: np.ndarray, dz: int, dx: int, fill: Any) -> np.ndarray:
    """``a`` shifted so ``out[z, x] == a[z + dz, x + dx]``; a cell shifted in from outside the array gets ``fill``."""
    nz, nx = a.shape
    out = np.full_like(a, fill)
    oz, ox = slice(max(0, -dz), nz - max(0, dz)), slice(max(0, -dx), nx - max(0, dx))
    az, ax = slice(max(0, dz), nz - max(0, -dz)), slice(max(0, dx), nx - max(0, -dx))
    out[oz, ox] = a[az, ax]
    return out


def slope_map(hm: Heightmap) -> np.ndarray:
    """Per column, the largest absolute height step to a four-neighbour also inside the map; ``-1`` where none is."""
    heights, valid = hm.heights, hm.heights >= 0
    slope = np.full(heights.shape, -1, dtype=np.int32)
    for dz, dx in NEIGHBORS4:
        neighbour, there = _shift(heights, dz, dx, 0), _shift(valid, dz, dx, False)
        slope = np.maximum(slope, np.where(valid & there, np.abs(heights - neighbour), -1))
    return slope


@dataclass
class TerrainStats:
    """Height range and mean over non-empty columns; ``flat_fraction`` and ``water_fraction`` are shares of them."""

    world: str
    bounds: Bounds2D
    columns: int
    min: int | None = None
    max: int | None = None
    mean: float | None = None
    water_fraction: float | None = None
    flat_fraction: float | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "world": self.world, "bounds": self.bounds.to_json(), "columns": self.columns,
            "min": self.min, "max": self.max, "mean": self.mean,
            "water_fraction": self.water_fraction, "flat_fraction": self.flat_fraction,
        }


def analyze_terrain(hm: Heightmap, *, flat_slope: int = 1) -> TerrainStats:
    """Height stats, the fraction of columns whose slope is at most ``flat_slope``, and the liquid fraction.

    A column with no in-map neighbour never counts as flat: a lone valid
    column beside nothing but empty ones has no evidence either way.
    """
    if flat_slope < 0:
        raise ValueError(f"flat_slope must be at least 0, got {flat_slope}")
    valid = hm.heights >= 0
    stats = TerrainStats(hm.world, hm.bounds, int(valid.sum()))
    if not valid.any():
        return stats
    heights = hm.heights[valid]
    stats.min, stats.max, stats.mean = int(heights.min()), int(heights.max()), float(heights.mean())
    slope = slope_map(hm)
    stats.flat_fraction = float((valid & (slope >= 0) & (slope <= flat_slope)).sum() / valid.sum())
    if hm.top is not None:
        stats.water_fraction = float(_liquid(hm)[valid].mean())
    return stats


@dataclass(frozen=True)
class Site:
    """A candidate build site: ``x, z`` its centre, ``bounds`` the window, ``height`` its mean ground height."""

    world: str
    bounds: Bounds2D
    x: int
    z: int
    height: int
    range: int
    slope_max: int
    water_fraction: float
    score: float

    def to_json(self) -> dict[str, Any]:
        return {
            "world": self.world, "bounds": self.bounds.to_json(), "x": self.x, "z": self.z, "height": self.height,
            "range": self.range, "slope_max": self.slope_max, "water_fraction": self.water_fraction, "score": self.score,
        }


def find_flat_site(
    hm: Heightmap, size: int, *, max_slope: int = 1, max_range: int | None = None, max_water: float = 0.0,
    near: Sequence[int] | None = None, limit: int = 5, suppress: int | None = None,
) -> list[Site]:
    """Every ``size``-square window entirely inside ``hm`` within the limits, scored, thinned, then ranked.

    A window qualifies when every column is known, its worst slope is at most
    ``max_slope``, its height range is at most ``max_range`` (default
    ``size``) and its liquid share is at most ``max_water``. Lower ``score``
    (range plus a water penalty) is better. Non-maximum suppression keeps only
    the best-scoring window within ``suppress`` blocks (default ``size``,
    centre to centre) of any window already kept, so an area of many
    qualifying windows names one site, not a cluster of near-duplicates.
    Survivors are ranked by squared distance to ``near`` (``x, z`` or
    ``x, y, z``) when given, else by score.
    """
    if size < 1:
        raise ValueError(f"size must be at least 1, got {size}")
    if min(hm.bounds.size) < size:
        raise ValueError(f"heightmap {hm.bounds.size} is smaller than site size {size}")
    max_range = size if max_range is None else max_range
    suppress = size if suppress is None else suppress
    if max_range < 0 or max_water < 0 or limit < 1 or suppress < 0:
        raise ValueError("max_range and max_water must be at least 0, limit at least 1, suppress at least 0")

    valid = hm.heights >= 0
    heights = np.where(valid, hm.heights, 0).astype(np.int64)
    slope = np.where(valid, slope_map(hm), 0)
    liquid = _liquid(hm)

    def _windows(a: np.ndarray) -> np.ndarray:
        return sliding_window_view(a, (size, size))

    v, h, s, w = _windows(valid), _windows(heights), _windows(slope), _windows(liquid)
    count = v.sum(axis=(2, 3))
    complete = count == size * size
    hi = np.where(v, h, np.iinfo(np.int64).min).max(axis=(2, 3))
    lo = np.where(v, h, np.iinfo(np.int64).max).min(axis=(2, 3))
    mean_h = np.divide(h.sum(axis=(2, 3)), np.maximum(count, 1))
    rng, smax, water = hi - lo, s.max(axis=(2, 3)), w.mean(axis=(2, 3))

    ok = complete & (smax <= max_slope) & (rng <= max_range) & (water <= max_water)
    score = rng.astype(float) + water * (size * size)
    x0, z0 = hm.bounds.min

    candidates = sorted(
        (
            (
                float(score[iz, ix]), int(x0 + ix), int(z0 + iz),
                int(round(mean_h[iz, ix])), int(rng[iz, ix]), int(smax[iz, ix]), float(water[iz, ix]),
            )
            for iz, ix in np.argwhere(ok)
        ),
        key=lambda c: c[0],
    )

    kept: list[tuple[float, int, int, int, int, int, float]] = []
    for cand in candidates:
        cx, cz = cand[1] + size // 2, cand[2] + size // 2
        if all(max(abs(cx - (k[1] + size // 2)), abs(cz - (k[2] + size // 2))) > suppress for k in kept):
            kept.append(cand)

    if near is not None:
        nx, nz = (near[0], near[1]) if len(near) == 2 else (near[0], near[2])
        kept.sort(key=lambda c: (c[1] + size // 2 - nx) ** 2 + (c[2] + size // 2 - nz) ** 2)

    return [
        Site(hm.world, Bounds2D((x, z), (x + size - 1, z + size - 1)), x + size // 2, z + size // 2, height, rng_, smax_, water_, sc)
        for sc, x, z, height, rng_, smax_, water_ in kept[:limit]
    ]


def _feather_t(x: int, z: int, bounds: Bounds2D, feather: int) -> float:
    """0 at the edge of ``bounds``, ramping to 1 by ``feather`` blocks in; always 1 when ``feather`` is 0."""
    if feather <= 0:
        return 1.0
    (x0, z0), (x1, z1) = bounds.min, bounds.max
    depth = min(x - x0, x1 - x, z - z0, z1 - z)
    return 1.0 if depth >= feather else max(depth, 0) / feather


def _smoothed_heights(heights: np.ndarray, valid: np.ndarray, radius: int) -> np.ndarray:
    """Mean of the valid heights in the Chebyshev ``radius`` neighbourhood, each column's own height included."""
    total, count = np.zeros(heights.shape), np.zeros(heights.shape)
    for dz in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            there = _shift(valid, dz, dx, False)
            total += np.where(there, _shift(heights, dz, dx, 0.0), 0.0)
            count += there
    return np.divide(total, count, out=heights.copy(), where=count > 0)


def _coalesce_fills(spans: Mapping[tuple[int, int], tuple[int, int, str]]) -> list[Fill]:
    """Column ``(x, z)`` to ``(y_min, y_max, block)`` merged into the fewest axis-aligned ``Fill`` boxes.

    Consecutive columns along x with an identical span become one run; consecutive
    z rows whose runs match exactly become one box, so a rectangle of columns
    that all need the same fill is one ``Fill`` however many columns it spans.
    """
    by_z: dict[int, dict[int, tuple[int, int, str]]] = {}
    for (x, z), span in spans.items():
        by_z.setdefault(z, {})[x] = span

    runs_by_z: dict[int, list[tuple[int, int, tuple[int, int, str]]]] = {}
    for z, cols in by_z.items():
        runs: list[tuple[int, int, tuple[int, int, str]]] = []
        for x in sorted(cols):
            span = cols[x]
            if runs and runs[-1][1] == x - 1 and runs[-1][2] == span:
                runs[-1] = (runs[-1][0], x, span)
            else:
                runs.append((x, x, span))
        runs_by_z[z] = runs

    fills: list[Fill] = []
    zs, used = sorted(runs_by_z), set()
    for i, z in enumerate(zs):
        if z in used:
            continue
        runs, z_end = runs_by_z[z], z
        for z2 in zs[i + 1:]:
            if z2 != z_end + 1 or runs_by_z[z2] != runs:
                break
            z_end, used = z2, used | {z2}
        fills.extend(Fill(Bounds((x0, y0, z), (x1, y1, z_end)), block) for x0, x1, (y0, y1, block) in runs)
    return fills


def terraform(
    hm: Heightmap, bounds: Bounds2D, *, mode: str, level: int = 0, block: str = "minecraft:stone",
    feather: int = 0, smooth_radius: int = 2,
) -> EditList:
    """Edits that move every column of ``bounds`` toward ``level``, or toward a local blur for ``smooth``.

    ``flatten`` forces every column to ``level``; ``raise`` only builds columns
    below it up; ``lower`` only cuts columns above it down; ``smooth`` blurs
    each column toward the mean height within ``smooth_radius``. ``feather``
    blocks at the edge of ``bounds`` blend from the untouched terrain to the
    full effect, so the edit leaves no cliff at its border. A column with no
    known height is left alone. Every changed column becomes one vertical
    ``Fill``, ``block`` where it rises or air where it is cut, and adjacent
    columns needing the same fill coalesce into one box.
    """
    if mode not in MODES:
        raise ValueError(f"mode must be one of {MODES}, got {mode!r}")
    if feather < 0:
        raise ValueError(f"feather must be at least 0, got {feather}")
    if mode == "smooth" and smooth_radius < 1:
        raise ValueError(f"smooth_radius must be at least 1, got {smooth_radius}")
    if hm.bounds.intersect(bounds) != bounds:
        raise ValueError(f"terraform bounds {bounds.min}..{bounds.max} are not covered by the fetched heightmap {hm.bounds.min}..{hm.bounds.max}")

    valid = hm.heights >= 0
    smoothed = _smoothed_heights(hm.heights.astype(float), valid, smooth_radius) if mode == "smooth" else None

    spans: dict[tuple[int, int], tuple[int, int, str]] = {}
    for x in range(bounds.min[0], bounds.max[0] + 1):
        for z in range(bounds.min[1], bounds.max[1] + 1):
            iz, ix = hm.bounds.local((x, z))
            if not valid[iz, ix]:
                continue
            original = int(hm.heights[iz, ix])
            if mode == "flatten":
                raw = float(level)
            elif mode == "raise":
                raw = float(max(original, level))
            elif mode == "lower":
                raw = float(min(original, level))
            else:
                raw = float(smoothed[iz, ix])
            target = original + round((raw - original) * _feather_t(x, z, bounds, feather))
            if target == original:
                continue
            spans[(x, z)] = (original + 1, target, block) if target > original else (target + 1, original, AIR)

    return EditList(hm.world, _coalesce_fills(spans), {"terrain_mode": mode, "bounds": bounds.to_json(), "columns": len(spans)})
