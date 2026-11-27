"""Streaming reader for Bedrock ``.mcstructure`` files, little-endian NBT.

A ``block_indices`` layer is one signed 32-bit palette index per cell, 46.6 million
of them in the rift_prison structure. A list of ints at or above ``BULK_MIN`` is
never materialised: ``on_indices`` receives it as numpy chunks while the file is
read once, in order. Everything else comes back as dicts and lists.

The file puts the indices ahead of the palette. Index ``i`` is the cell at
``(i // (sy * sz), i // sz % sy, i % sz)``, z fastest, and -1 means no block.
"""

from __future__ import annotations

import gzip
import struct
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import IO, Any

import numpy as np

from designer.blocks import format_name

BULK_MIN = 1 << 16
CHUNK_CELLS = 1 << 20

BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, BYTE_ARRAY, STRING, LIST, COMPOUND, INT_ARRAY, LONG_ARRAY = range(1, 13)
_FIXED = {BYTE: "b", SHORT: "h", INT: "i", LONG: "q", FLOAT: "f", DOUBLE: "d"}

IndexHandler = Callable[[int, Iterator[tuple[int, np.ndarray]]], None]


class StructureError(ValueError):
    """The bytes are not a structure this reader understands."""


class Byte(int):
    """A TAG_Byte, kept apart from TAG_Int so a boolean state stays a boolean."""


@dataclass(frozen=True)
class BlockState:
    name: str
    states: dict[str, bool | int | str]
    version: int

    @property
    def key(self) -> str:
        return format_name(self.name, self.states)


@dataclass
class Structure:
    size: tuple[int, int, int]
    palette: list[BlockState] = field(default_factory=list)
    # Keyed by layer-0 cell index; the value is the block entity's own tag.
    block_entities: dict[int, dict[str, Any]] = field(default_factory=dict)
    entities: list[dict[str, Any]] = field(default_factory=list)

    @property
    def cells(self) -> int:
        return self.size[0] * self.size[1] * self.size[2]


def open_structure(path: Path) -> IO[bytes]:
    """The structure's uncompressed bytes, whether ``path`` is gzipped or not."""
    raw = open(path, "rb")
    gzipped = raw.read(2) == b"\x1f\x8b"
    raw.seek(0)
    return gzip.GzipFile(fileobj=raw, mode="rb") if gzipped else raw


class _Reader:
    def __init__(self, stream: IO[bytes], on_indices: IndexHandler | None) -> None:
        self._s, self._on_indices = stream, on_indices

    def take(self, n: int) -> bytes:
        data = self._s.read(n)
        if len(data) != n:
            raise StructureError(f"truncated: wanted {n} bytes, got {len(data)}")
        return data

    def fixed(self, fmt: str, count: int | None = None) -> Any:
        n = 1 if count is None else count
        values = struct.unpack(f"<{n}{fmt}", self.take(n * struct.calcsize(fmt)))
        return values[0] if count is None else list(values)

    def string(self) -> str:
        return self.take(self.fixed("H")).decode("utf-8")

    def payload(self, tag: int, path: tuple[Any, ...]) -> Any:
        if tag == BYTE:
            return Byte(self.fixed("b"))
        if tag in _FIXED:
            return self.fixed(_FIXED[tag])
        if tag == STRING:
            return self.string()
        if tag == BYTE_ARRAY:
            return self.take(self.fixed("i"))
        if tag == COMPOUND:
            out: dict[str, Any] = {}
            while (kind := self.fixed("B")) != 0:
                name = self.string()
                out[name] = self.payload(kind, (*path, name))
            return out
        if tag == LIST:
            return self.read_list(path)
        if tag in (INT_ARRAY, LONG_ARRAY):
            return self.fixed("i" if tag == INT_ARRAY else "q", self.fixed("i"))
        raise StructureError(f"unknown tag type {tag} at {'/'.join(map(str, path))}")

    def read_list(self, path: tuple[Any, ...]) -> list[Any] | None:
        elem, count = self.fixed("B"), self.fixed("i")
        if elem == INT and count >= BULK_MIN:
            if self._on_indices is None or path[-2:-1] != ("block_indices",):
                raise StructureError(f"{count} ints at {'/'.join(map(str, path))} and nothing to stream them to")
            chunks = self.int_chunks(count)
            self._on_indices(path[-1], chunks)
            for _ in chunks:
                pass
            return None
        if elem in _FIXED:
            return self.fixed(_FIXED[elem], max(count, 0))
        return [self.payload(elem, (*path, i)) for i in range(max(count, 0))]

    def int_chunks(self, count: int) -> Iterator[tuple[int, np.ndarray]]:
        for start in range(0, count, CHUNK_CELLS):
            n = min(CHUNK_CELLS, count - start)
            yield start, np.frombuffer(self.take(n * 4), dtype="<i4")


def read_structure(stream: IO[bytes], on_indices: IndexHandler | None = None) -> Structure:
    """Parse ``stream``, handing each ``block_indices`` layer to ``on_indices(layer, chunks)``.

    ``chunks`` yields ``(start, int32 array)`` pairs. Without a handler a structure
    with a layer that long is refused rather than materialised.
    """
    reader = _Reader(stream, on_indices)
    if reader.fixed("B") != COMPOUND:
        raise StructureError("root is not a compound")
    reader.string()
    root = reader.payload(COMPOUND, ())
    if "size" not in root or "structure" not in root:
        raise StructureError("no structure or size tag")
    structure = root["structure"]
    out = Structure(size=tuple(root["size"]), entities=structure.get("entities") or [])
    default = structure.get("palette", {}).get("default", {})
    for entry in default.get("block_palette", []):
        out.palette.append(BlockState(entry["name"], _states(entry.get("states", {})), entry.get("version", 0)))
    for index, data in default.get("block_position_data", {}).items():
        if "block_entity_data" in data:
            out.block_entities[int(index)] = data["block_entity_data"]
    return out


def _states(raw: dict[str, Any]) -> dict[str, bool | int | str]:
    # Bedrock stores a boolean state as a byte tag. Returning a bool keeps a JSON
    # census able to tell a byte state from an int state.
    out: dict[str, bool | int | str] = {}
    for key, value in raw.items():
        if isinstance(value, Byte):
            if value not in (0, 1):
                raise StructureError(f"byte state {key}={int(value)} is not a boolean")
            value = bool(value)
        out[key] = value
    return out
