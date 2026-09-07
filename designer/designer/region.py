"""Inclusive block bounds, tiling, and the in-memory region model."""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from functools import reduce
from itertools import product
from typing import Any, ClassVar, Self

import numpy as np

from designer.blocks import AIR, class_lut, decode_rle, encode_rle

# The bridge's ``max_region_edge``; any request with a longer edge is refused.
MAX_EDGE = 128


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

    def slices(self, inner: Bounds) -> tuple[slice, slice, slice]:
        """Array slices of ``inner``, which must lie entirely within this box."""
        if self.intersect(inner) != inner:
            raise ValueError(f"{inner.min}..{inner.max} is not inside {self.min}..{self.max}")
        lo, hi = self.local(inner.min), self.local(inner.max)
        return tuple(slice(a, b + 1) for a, b in zip(lo, hi))


class Bounds2D(_Box):
    """Inclusive ``(x, z)`` bounds for heightmaps and top-down renders."""

    AXES = "xz"


@dataclass(eq=False)
class Region:
    """One world's blocks inside ``bounds``, as ``blocks[y][z][x]`` over ``palette``."""

    world: str
    bounds: Bounds
    blocks: np.ndarray
    palette: list[str]
    _parent: Region | None = field(default=None, repr=False)
    _classes: np.ndarray | None = field(default=None, init=False, repr=False)

    def __post_init__(self) -> None:
        if self.blocks.shape != self.bounds.shape:
            raise ValueError(f"blocks shape {self.blocks.shape} does not match bounds shape {self.bounds.shape}")
        if not self.palette or self.palette[0] != AIR:
            raise ValueError(f"palette must start with {AIR!r}, got {self.palette[:1]!r}")

    @classmethod
    def empty(cls, world: str, bounds: Bounds, fill: str = AIR) -> Region:
        palette = [AIR] if fill == AIR else [AIR, fill]
        return cls(world, bounds, np.full(bounds.shape, len(palette) - 1, dtype=np.int16), palette)

    @classmethod
    def from_rle(cls, world: str, payload: dict[str, Any]) -> Region:
        blocks, palette = decode_rle(payload)
        return cls(world, Bounds(tuple(payload["min"]), tuple(payload["max"])), blocks, palette)

    @classmethod
    def merge(cls, tiles: Iterable[Region]) -> Region:
        """One region over the union of the tiles. Where tiles overlap, the later one wins."""
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

    def classes(self) -> np.ndarray:
        """``BlockClass`` per block as uint8, cached until the next ``set``."""
        if self._parent is not None:
            return self._parent.classes()[self._parent.bounds.slices(self.bounds)]
        if self._classes is None:
            self._classes = class_lut(self.palette)[self.blocks]
        return self._classes

    def counts(self) -> dict[str, int]:
        """Blocks per palette name, omitting names that do not occur."""
        totals = np.bincount(self.blocks.ravel(), minlength=len(self.palette))
        return {name: int(n) for name, n in zip(self.palette, totals) if n}
