"""Inclusive block bounds, tiling, the in-memory region model, and the fetch helpers."""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from functools import reduce
from itertools import product
from typing import Any, ClassVar, Self

import numpy as np

from designer.blocks import AIR, BlockClass, base_name, class_lut, decode_rle, encode_rle
from designer.bridge import Bridge

# The bridge's ``max_region_edge``; any request with a longer edge is refused.
MAX_EDGE = 128

# Blocks a ground heightmap looks through, so a tree is not a surface.
CANOPY_SUFFIXES = ("_leaves", "_log", "_wood")


def _spans(lo: int, hi: int, max_edge: int) -> list[tuple[int, int]]:
    return [(a, min(a + max_edge - 1, hi)) for a in range(lo, hi + 1, max_edge)]


@dataclass(frozen=True)
class _Box:
    """An inclusive box: ``min`` and ``max`` both name blocks inside it."""

    min: tuple[int, ...]
    max: tuple[int, ...]
    AXES: ClassVar[str] = ""

    def __post_init__(self) -> None:
        pairs = list(zip(self.min, self.max, strict=True))
        if len(pairs) != len(self.AXES):
            raise ValueError(f"{type(self).__name__} takes {len(self.AXES)} coordinates, got {len(pairs)}")
        object.__setattr__(self, "min", tuple(int(min(p)) for p in pairs))
        object.__setattr__(self, "max", tuple(int(max(p)) for p in pairs))

    @classmethod
    def from_size(cls, lo: Sequence[int], size: Sequence[int]) -> Self:
        if min(size) < 1:
            raise ValueError(f"size must be at least 1 on every axis, got {tuple(size)!r}")
        return cls(tuple(lo), tuple(a + s - 1 for a, s in zip(lo, size, strict=True)))

    @classmethod
    def from_center(cls, center: Sequence[int], size: Sequence[int]) -> Self:
        """Box of ``size`` around ``center``.

        An even size has no middle block, so ``center`` is the upper of the two
        middle blocks: ``min = center - size // 2``.
        """
        return cls.from_size(tuple(c - s // 2 for c, s in zip(center, size, strict=True)), size)

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> Self:
        return cls(tuple(data["min"]), tuple(data["max"]))

    def to_json(self) -> dict[str, list[int]]:
        return {"min": list(self.min), "max": list(self.max)}

    @property
    def size(self) -> tuple[int, ...]:
        return tuple(hi - lo + 1 for lo, hi in zip(self.min, self.max))

    @property
    def volume(self) -> int:
        return int(np.prod(self.size))

    def contains(self, pos: Sequence[int]) -> bool:
        return all(lo <= p <= hi for lo, p, hi in zip(self.min, pos, self.max, strict=True))

    def intersect(self, other: Self) -> Self | None:
        lo = tuple(map(max, self.min, other.min))
        hi = tuple(map(min, self.max, other.max))
        return None if any(a > b for a, b in zip(lo, hi)) else type(self)(lo, hi)

    def union(self, other: Self) -> Self:
        return type(self)(tuple(map(min, self.min, other.min)), tuple(map(max, self.max, other.max)))

    def expand(self, n: int, axes: str | None = None) -> Self:
        """Grow by ``n`` blocks on both ends of each named axis, every axis when ``None``."""
        axes = self.AXES if axes is None else axes
        if set(axes) - set(self.AXES):
            raise ValueError(f"axes must be drawn from {self.AXES!r}, got {axes!r}")
        grow = tuple(n if a in axes else 0 for a in self.AXES)
        return type(self)(tuple(a - g for a, g in zip(self.min, grow)), tuple(a + g for a, g in zip(self.max, grow)))

    def tiles(self, max_edge: int = MAX_EDGE) -> list[Self]:
        """Boxes covering every block exactly once, no edge longer than ``max_edge``."""
        if max_edge < 1:
            raise ValueError(f"max_edge must be at least 1, got {max_edge}")
        spans = [_spans(lo, hi, max_edge) for lo, hi in zip(self.min, self.max)]
        return [type(self)(tuple(s[0] for s in cell), tuple(s[1] for s in cell)) for cell in product(*spans)]

    def slices(self, inner: Self) -> tuple[slice, ...]:
        """Array slices of ``inner``, which must lie entirely within this box."""
        if self.intersect(inner) != inner:
            raise ValueError(f"{inner.min}..{inner.max} is not inside {self.min}..{self.max}")
        lo, hi = self.local(inner.min), self.local(inner.max)
        return tuple(slice(a, b + 1) for a, b in zip(lo, hi))


class Bounds(_Box):
    """Inclusive ``(x, y, z)`` bounds. Array indexing goes through ``local`` and ``slices``."""

    AXES = "xyz"

    @property
    def shape(self) -> tuple[int, int, int]:
        """Array shape ``(ny, nz, nx)`` matching ``blocks[y][z][x]``."""
        sx, sy, sz = self.size
        return sy, sz, sx

    def local(self, pos: Sequence[int]) -> tuple[int, int, int]:
        """Array index ``(iy, iz, ix)`` of the block at ``pos``."""
        if not self.contains(pos):
            raise ValueError(f"{tuple(pos)!r} is outside {self.min}..{self.max}")
        x, y, z = (p - lo for p, lo in zip(pos, self.min))
        return y, z, x


class Bounds2D(_Box):
    """Inclusive ``(x, z)`` bounds for heightmaps and top-down renders."""

    AXES = "xz"

    @property
    def shape(self) -> tuple[int, int]:
        """Array shape ``(nz, nx)`` matching ``heights[z][x]``."""
        sx, sz = self.size
        return sz, sx

    def local(self, pos: Sequence[int]) -> tuple[int, int]:
        """Array index ``(iz, ix)`` of the column at ``pos``."""
        if not self.contains(pos):
            raise ValueError(f"{tuple(pos)!r} is outside {self.min}..{self.max}")
        x, z = (p - lo for p, lo in zip(pos, self.min))
        return z, x


@dataclass(eq=False)
class Region:
    """One world's blocks inside ``bounds``, as ``blocks[y][z][x]`` over ``palette``."""

    world: str
    bounds: Bounds
    blocks: np.ndarray
    palette: list[str]
    _parent: Region | None = field(default=None, repr=False)
    _classes: np.ndarray | None = field(default=None, init=False, repr=False)
    _stand: np.ndarray | None = field(default=None, init=False, repr=False)

    def __post_init__(self) -> None:
        if self.blocks.shape != self.bounds.shape:
            raise ValueError(f"blocks shape {self.blocks.shape} does not match bounds shape {self.bounds.shape}")
        if self.blocks.dtype != np.int16:
            raise ValueError(f"blocks must be int16, got {self.blocks.dtype}")
        if not self.palette or self.palette[0] != AIR:
            raise ValueError(f"palette must start with {AIR!r}, got {self.palette[:1]!r}")

    @classmethod
    def empty(cls, world: str, bounds: Bounds, fill: str = AIR) -> Region:
        palette = [AIR] if fill == AIR else [AIR, fill]
        return cls(world, bounds, np.full(bounds.shape, len(palette) - 1, dtype=np.int16), palette)

    @classmethod
    def from_rle(cls, world: str, payload: dict[str, Any]) -> Region:
        """Decode a region payload; a payload naming a different ``world`` is refused."""
        claimed = payload.get("world")
        if claimed is not None and claimed != world:
            raise ValueError(f"payload is from world {claimed!r}, expected {world!r}")
        blocks, palette = decode_rle(payload)
        return cls(world, Bounds(tuple(payload["min"]), tuple(payload["max"])), blocks, palette)

    @classmethod
    def merge(cls, tiles: Iterable[Region]) -> Region:
        """One region over the union of the tiles: later tiles win overlaps, uncovered blocks are air."""
        tiles = list(tiles)
        if not tiles:
            raise ValueError("merge needs at least one tile")
        if len({t.world for t in tiles}) != 1:
            raise ValueError(f"tiles span several worlds: {sorted({t.world for t in tiles})}")
        out = cls.empty(tiles[0].world, reduce(Bounds.union, (t.bounds for t in tiles)))
        index: dict[str, int] = {AIR: 0}
        for tile in tiles:
            lut = np.array([index.setdefault(name, len(index)) for name in tile.palette], dtype=np.int16)
            out.blocks[out.bounds.slices(tile.bounds)] = lut[tile.blocks]
        out.palette[:] = index
        return out

    def to_rle(self) -> dict[str, Any]:
        payload = encode_rle(self.blocks, self.palette, origin=self.bounds.min)
        payload["world"] = self.world
        return payload

    def _invalidate(self) -> None:
        region: Region | None = self
        while region is not None:
            region._classes = None
            region._stand = None
            region = region._parent

    def index_of(self, name: str, add: bool = True) -> int:
        try:
            return self.palette.index(name)
        except ValueError:
            if not add:
                raise KeyError(name) from None
            self.palette.append(name)
            self._invalidate()
            return len(self.palette) - 1

    def get(self, x: int, y: int, z: int) -> str:
        return self.palette[int(self.blocks[self.bounds.local((x, y, z))])]

    def set(self, x: int, y: int, z: int, name: str) -> None:
        self.blocks[self.bounds.local((x, y, z))] = self.index_of(name)
        self._invalidate()

    def sub(self, bounds: Bounds) -> Region:
        """A view over the part of this region inside ``bounds``; edits show in both."""
        inner = self.bounds.intersect(bounds)
        if inner is None:
            raise ValueError(f"{bounds.min}..{bounds.max} does not touch {self.bounds.min}..{self.bounds.max}")
        return Region(self.world, inner, self.blocks[self.bounds.slices(inner)], self.palette, _parent=self)

    def fill(self, bounds: Bounds, name: str) -> None:
        """Every block inside ``bounds`` becomes ``name``."""
        self.sub(bounds).blocks[...] = self.index_of(name)
        self._invalidate()

    def replace(self, bounds: Bounds, sources: Iterable[str], name: str) -> None:
        """Every block inside ``bounds`` whose name is in ``sources`` becomes ``name``."""
        view, wanted = self.sub(bounds), set(sources)
        matches = [i for i, entry in enumerate(self.palette) if entry in wanted]
        view.blocks[np.isin(view.blocks, matches)] = self.index_of(name)
        self._invalidate()

    def classes(self) -> np.ndarray:
        """``BlockClass`` per block as uint8, cached until the next ``set``, ``fill``, ``replace`` or ``index_of``."""
        if self._parent is not None:
            return self._parent.classes()[self._parent.bounds.slices(self.bounds)]
        if self._classes is None:
            self._classes = class_lut(self.palette)[self.blocks]
        return self._classes

    def passable(self) -> np.ndarray:
        """Bool per block: air, or a block a player walks through."""
        classes = self.classes()
        return (classes == BlockClass.AIR) | (classes == BlockClass.PASSABLE)

    def stand_mask(self) -> np.ndarray:
        """Bool ``[y][z][x]``: a player can stand with feet in the cell.

        Solid floor below, the cell and the one above passable. The top and
        bottom layers are never standable because their floor or head cell is
        outside the region. The mask depends on nothing but the blocks, so the
        root region caches it beside ``classes`` and ``_invalidate`` clears
        both; a view computes fresh every call because an edit made through
        its parent never reaches the view's cache.
        """
        if self._parent is None and self._stand is not None:
            return self._stand
        classes, passable = self.classes(), self.passable()
        mask = np.zeros(classes.shape, dtype=bool)
        if classes.shape[0] >= 3:
            mask[1:-1] = (classes[:-2] == BlockClass.SOLID) & passable[1:-1] & passable[2:]
        if self._parent is None:
            self._stand = mask
        return mask

    def counts(self) -> dict[str, int]:
        """Blocks per palette name, omitting names that do not occur."""
        totals = np.bincount(self.blocks.ravel(), minlength=len(self.palette))
        return {name: int(n) for name, n in zip(self.palette, totals) if n}


@dataclass(eq=False)
class Heightmap:
    """Highest block per column as ``heights[z][x]``, ``-1`` for an empty column.

    ``top`` is that block's palette index, air for an empty column, or ``None``
    when the source did not report it.
    """

    world: str
    bounds: Bounds2D
    heights: np.ndarray
    top: np.ndarray | None = None
    palette: list[str] = field(default_factory=lambda: [AIR])

    def __post_init__(self) -> None:
        for name, array in (("heights", self.heights), ("top", self.top)):
            if array is not None and (array.shape != self.bounds.shape or array.dtype != np.int16):
                raise ValueError(f"{name} must be int16 of shape {self.bounds.shape}, got {array.dtype} {array.shape}")

    @classmethod
    def merge(cls, tiles: Iterable[Heightmap]) -> Heightmap:
        """One heightmap over the union of the tiles: later tiles win overlaps, uncovered columns are empty.

        ``top`` is kept only when every tile carries one.
        """
        tiles = list(tiles)
        if not tiles:
            raise ValueError("merge needs at least one tile")
        if len({t.world for t in tiles}) != 1:
            raise ValueError(f"tiles span several worlds: {sorted({t.world for t in tiles})}")
        bounds = reduce(Bounds2D.union, (t.bounds for t in tiles))
        with_top = all(t.top is not None for t in tiles)
        out = cls(tiles[0].world, bounds, np.full(bounds.shape, -1, dtype=np.int16), np.zeros(bounds.shape, dtype=np.int16) if with_top else None)
        index: dict[str, int] = {AIR: 0}
        for tile in tiles:
            at = bounds.slices(tile.bounds)
            out.heights[at] = tile.heights
            if with_top:
                lut = np.array([index.setdefault(name, len(index)) for name in tile.palette], dtype=np.int16)
                out.top[at] = lut[tile.top]
        out.palette[:] = index
        return out

    def height(self, x: int, z: int) -> int:
        return int(self.heights[self.bounds.local((x, z))])

    def top_name(self, x: int, z: int) -> str:
        if self.top is None:
            raise ValueError("heightmap carries no top blocks; fetch it with need_top=True")
        return self.palette[int(self.top[self.bounds.local((x, z))])]


def fetch_region(bridge: Bridge, world: str, bounds: Bounds, *, max_edge: int = MAX_EDGE) -> Region:
    """The blocks inside ``bounds``, one ``get_region`` job per tile of ``max_edge``."""
    return Region.merge(
        Region.from_rle(world, bridge.call_job("get_region", world=world, bounds=t.to_json())["result"])
        for t in bounds.tiles(max_edge)
    )


def fetch_heightmap(bridge: Bridge, world: str, bounds: Bounds2D, *, need_top: bool = False) -> Heightmap:
    """Highest block per column inside ``bounds``, one ``get_heightmap`` job per tile.

    ``need_top`` guarantees the top blocks: when the server reports none, the
    tile's observed height range is fetched as a region and the tops derived.
    """
    tiles = []
    for tile in bounds.tiles():
        result = bridge.call_job("get_heightmap", world=world, bounds=tile.to_json())["result"]
        heights = np.asarray(result["heights"], dtype=np.int16).reshape(tile.shape)
        top, palette = None, [AIR]
        if result.get("top") is not None:
            top, palette = np.asarray(result["top"], dtype=np.int16).reshape(tile.shape), list(result["palette"])
            if AIR not in palette:
                palette.append(AIR)
            top[heights < 0] = palette.index(AIR)
        elif need_top:
            top = np.zeros(tile.shape, dtype=np.int16)
            if (heights >= 0).any():
                lo, hi = int(heights[heights >= 0].min()), int(heights.max())
                box = Bounds((tile.min[0], lo, tile.min[1]), (tile.max[0], hi, tile.max[1]))
                derived = heightmap_from_region(fetch_region(bridge, world, box))
                top, palette = derived.top, derived.palette
        tiles.append(Heightmap(world, tile, heights, top, palette))
    return Heightmap.merge(tiles)


def heightmap_from_region(region: Region, *, ground: bool = False) -> Heightmap:
    """Highest non-air block per column; ``ground`` also looks through passable blocks and trees."""
    skip = region.classes() == BlockClass.AIR
    if ground:
        canopy = np.array([base_name(name).endswith(CANOPY_SUFFIXES) for name in region.palette])
        skip |= (region.classes() == BlockClass.PASSABLE) | canopy[region.blocks]
    surface = ~skip
    iy = surface.shape[0] - 1 - surface[::-1].argmax(axis=0)
    found = surface.any(axis=0)
    heights = np.where(found, iy + region.bounds.min[1], -1).astype(np.int16)
    top = np.where(found, np.take_along_axis(region.blocks, iy[None], axis=0)[0], 0).astype(np.int16)
    (x0, _, z0), (x1, _, z1) = region.bounds.min, region.bounds.max
    return Heightmap(region.world, Bounds2D((x0, z0), (x1, z1)), heights, top, list(region.palette))
