"""Text and PNG rendering of a heightmap, plus the marker and report-path helpers every render shares."""

from __future__ import annotations

import colorsys
import math
import zlib
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from designer.blocks import AIR, NAMESPACE, BlockClass, base_name, class_lut
from designer.config import REPORTS_DIR
from designer.region import Bounds2D, Heightmap
from designer.world_index import WorldIndex

# Low to high. Space is reserved for an empty column and ``~`` for liquid.
RAMP = ".,:-=+*#%@"
LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
# Chunk edges, so a tick on the map is a boundary a player can also see.
TICK = 16
# The bridge's largest region edge, so a heavy gridline is also a tile edge.
HEAVY = 128
# Pixel rows per legend line; the default font is 11 px tall.
LEGEND_LINE = 12
GRID_COLOR, TEXT_COLOR = (200, 200, 200), (255, 255, 255)
MARKER_FILL = {"location": (255, 40, 40), "corner": (255, 220, 0)}
WATER_TINT = np.array([40, 90, 220], dtype=float)


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


def _ticks(lo: int, hi: int, step: int, every: int = TICK) -> dict[int, str]:
    return {(v - lo) // step: str(v) for v in range(-(-lo // every) * every, hi + 1, every)}


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


def fallback_color(base: str) -> tuple[int, int, int]:
    """A stable colour for a block with no entry in ``colors``: the hue is a crc32 of its base name."""
    hue = (zlib.crc32(base.encode()) & 0xFFFF) / 0x10000
    return tuple(int(c * 255) for c in colorsys.hsv_to_rgb(hue, 0.55, 0.85))


def _palette_colors(palette: list[str], colors: Mapping[str, Any]) -> tuple[np.ndarray, dict[str, tuple[int, int, int]]]:
    """RGB per palette index, and each base name that fell back to a hashed colour."""
    lut, hashed = np.zeros((len(palette), 3)), {}
    for i, name in enumerate(palette):
        base = base_name(name)
        if NAMESPACE + base in colors:
            lut[i] = colors[NAMESPACE + base]
        else:
            hashed[base] = lut[i] = fallback_color(base)
    return lut, hashed


def topdown_png(
    hm: Heightmap, colors: Mapping[str, Any], markers: Iterable[Marker] = (), *,
    scale: int = 4, grid: int = 16, out: Path | str | None = None,
) -> Path:
    """Write a top-down PNG, one ``scale`` pixel square per column, and return its path."""
    if scale < 1 or grid < 1:
        raise ValueError(f"scale and grid must be at least 1, got {scale} and {grid}")
    (xmin, zmin), (xmax, zmax) = hm.bounds.min, hm.bounds.max
    nz, nx = hm.heights.shape
    valid = hm.heights >= 0
    top, palette = (hm.top, hm.palette) if hm.top is not None else (np.where(valid, 1, 0), [AIR, "unknown"])
    lut, hashed = _palette_colors(palette, colors)
    stats = summary(hm)
    lo, hi = (0, 0) if stats["min"] is None else (stats["min"], stats["max"])
    heights = np.where(valid, hm.heights, lo).astype(float)
    # Lit from the west: a slope rising eastward faces the light and brightens.
    slope = np.gradient(heights, axis=1) if nx > 1 else np.zeros_like(heights)
    shade = (0.55 + 0.45 * (heights - lo) / max(hi - lo, 1)) * np.clip(1 + 0.12 * slope, 0.7, 1.3)
    rgb = lut[top] * shade[..., None]
    liquid = _liquid(hm)
    rgb[liquid] = rgb[liquid] * 0.5 + WATER_TINT * 0.5
    rgb[~valid] = 0
    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8)).resize((nx * scale, nz * scale), Image.Resampling.NEAREST)

    y_range = "empty" if stats["min"] is None else f"{lo}..{hi}"
    legend = [(None, f"world={hm.world} x={xmin}..{xmax} z={zmin}..{zmax} y={y_range} scale={scale}")]
    legend += sorted(((swatch, base) for base, swatch in hashed.items()), key=lambda e: e[1])
    canvas = Image.new("RGB", (img.width, img.height + LEGEND_LINE * len(legend)), (20, 20, 20))
    canvas.paste(img, (0, 0))
    draw, font = ImageDraw.Draw(canvas), ImageFont.load_default()
    for ix, label in _ticks(xmin, xmax, 1, grid).items():
        draw.line([(ix * scale, 0), (ix * scale, img.height - 1)], fill=GRID_COLOR, width=2 if (xmin + ix) % HEAVY == 0 else 1)
        draw.text((ix * scale + 2, 0), label, fill=TEXT_COLOR, font=font)
    for iz, label in _ticks(zmin, zmax, 1, grid).items():
        draw.line([(0, iz * scale), (img.width - 1, iz * scale)], fill=GRID_COLOR, width=2 if (zmin + iz) % HEAVY == 0 else 1)
        draw.text((1, iz * scale + 1), label, fill=TEXT_COLOR, font=font)
    radius = max(3, scale)
    for m in markers:
        if hm.bounds.contains((m.x, m.z)):
            px, pz = (m.x - xmin) * scale + scale // 2, (m.z - zmin) * scale + scale // 2
            fill = MARKER_FILL.get(m.kind, MARKER_FILL["location"])
            draw.ellipse([px - radius, pz - radius, px + radius, pz + radius], fill=fill, outline=(0, 0, 0))
            draw.text((px + radius + 2, pz - 5), m.label, fill=TEXT_COLOR, font=font)
    for i, (swatch, text) in enumerate(legend):
        y = img.height + i * LEGEND_LINE
        if swatch is not None:
            draw.rectangle([2, y + 1, LEGEND_LINE - 2, y + LEGEND_LINE - 2], fill=swatch)
        draw.text((2 if swatch is None else LEGEND_LINE + 2, y), text, fill=TEXT_COLOR, font=font)

    path = report_path("topdown", hm.world, hm.bounds, "png") if out is None else Path(out)
    path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(path)
    return path


# Darkening applied to the +x and +z side faces respectively, so a block reads as three
# dimensional from a single flat top colour.
ISO_RIGHT_SHADE, ISO_LEFT_SHADE = 0.7, 0.5


def isometric_png(
    hm: Heightmap, colors: Mapping[str, Any], markers: Iterable[Marker] = (), *, scale: int = 2, out: Path | str | None = None,
) -> Path:
    """Write a 2:1 dimetric PNG and return its path.

    Each column draws a top rhombus in its block colour. A face towards its
    +x neighbour and one towards its +z neighbour are drawn only as deep as
    the height that neighbour falls short by, so a cliff gets a full face and
    a gentle ramp a shallow one; an edge or an empty neighbour counts as the
    heightmap's own low point. Columns paint back to front by ``ix + iz`` so
    a nearer column covers what lies behind it, and markers project the same
    way, drawn last.
    """
    if scale < 1:
        raise ValueError(f"scale must be at least 1, got {scale}")
    half_w, half_h = 2 * scale, scale
    xmin, zmin = hm.bounds.min
    nz, nx = hm.heights.shape
    valid = hm.heights >= 0
    top, palette = (hm.top, hm.palette) if hm.top is not None else (np.where(valid, 1, 0), [AIR, "unknown"])
    lut, _ = _palette_colors(palette, colors)
    stats = summary(hm)
    lo, hi = (0, 0) if stats["min"] is None else (stats["min"], stats["max"])
    span = hi - lo
    heights = np.where(valid, hm.heights, lo).astype(int)
    ox, oy = nz * half_w, half_h * (span + 1)

    def project(ix: int, iz: int, h: int) -> tuple[int, int]:
        return ox + (ix - iz) * half_w, oy + (ix + iz) * half_h - (h - lo) * half_h

    def neighbour(ix: int, iz: int) -> int:
        return int(heights[iz, ix]) if 0 <= ix < nx and 0 <= iz < nz and valid[iz, ix] else lo

    canvas = Image.new("RGB", (half_w * (nx + nz), half_h * (nx + nz + span)), (20, 20, 20))
    draw = ImageDraw.Draw(canvas)
    for ix, iz in sorted(((ix, iz) for iz in range(nz) for ix in range(nx)), key=lambda p: p[0] + p[1]):
        if not valid[iz, ix]:
            continue
        h = int(heights[iz, ix])
        cx, cy = project(ix, iz, h)
        rgb = tuple(int(c) for c in lut[top[iz, ix]])
        east, south, west = (cx + half_w, cy), (cx, cy + half_h), (cx - half_w, cy)
        draw.polygon([(cx, cy - half_h), east, south, west], fill=rgb)
        for corner, shade, drop in ((east, ISO_RIGHT_SHADE, h - neighbour(ix + 1, iz)), (west, ISO_LEFT_SHADE, h - neighbour(ix, iz + 1))):
            if drop > 0:
                face = tuple(int(c * shade) for c in rgb)
                draw.polygon([corner, south, (south[0], south[1] + drop * half_h), (corner[0], corner[1] + drop * half_h)], fill=face)

    for m in markers:
        if hm.bounds.contains((m.x, m.z)):
            px, py = project(m.x - xmin, m.z - zmin, m.y)
            fill = MARKER_FILL.get(m.kind, MARKER_FILL["location"])
            draw.ellipse([px - scale, py - scale, px + scale, py + scale], fill=fill, outline=(0, 0, 0))
            draw.text((px + scale + 2, py - 5), m.label, fill=TEXT_COLOR, font=ImageFont.load_default())

    path = report_path("isometric", hm.world, hm.bounds, "png") if out is None else Path(out)
    path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(path)
    return path
