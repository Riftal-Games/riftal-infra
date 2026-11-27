"""The ``structure`` builder: a pinned ``.mcstructure`` cut into the 16^3 cell files ``load_structure`` reads.

The cells sit on the world's 16 grid, not the structure's, so a structure whose minimum corner is not
16-aligned still lands in whole cells. A cell that holds only air is not written: the level's generator
is void, so nothing is there already. A structure cell with no state (index -1) is air.

Hard rule 1: the only block entity that survives is a bed's colour. Every other tile, an item list or a
campfire's four item slots included, is dropped here, and ``load_structure`` refuses one if a file ever
carried it.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Any

import numpy as np

from designer.blocks import AIR
from designer.bridge import Bridge
from designer.mcstructure import open_structure, read_structure

CELL = 16
MANIFEST = "manifest.json"
BED = "minecraft:bed"
DEFAULT_MAX_EDGE = 128


class StructureBuildError(ValueError):
    """The source cannot be turned into cells."""


@dataclass(frozen=True)
class StructureSpec:
    """A ``structure`` step's spec file."""

    world: str
    source: str
    file: str
    origin: tuple[int, int, int]
    min_corner: tuple[int, int, int]
    substitutes: dict[str, str]

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> StructureSpec:
        try:
            origin, corner, subs = (tuple(data["origin"]), tuple(data["min_corner"]), dict(data["substitutes"]))
            if len(origin) != 3 or len(corner) != 3 or not all(type(v) is int for v in (*origin, *corner)):
                raise TypeError("origin and min_corner are each three integers")
            if not all(isinstance(k, str) and isinstance(v, str) for k, v in subs.items()):
                raise TypeError("substitutes maps block names to block names")
            return cls(str(data["world"]), str(data["source"]), str(data["file"]), origin, corner, subs)  # type: ignore[arg-type]
        except (KeyError, TypeError, ValueError) as exc:
            raise StructureBuildError(f"cannot read the structure spec: {exc!r}") from exc

    def world_min(self) -> tuple[int, int, int]:
        """Where the structure's minimum corner lands: its local corner shifted by the origin."""
        return (self.origin[0] + self.min_corner[0], self.origin[1] + self.min_corner[1], self.origin[2] + self.min_corner[2])


@dataclass(frozen=True)
class Converted:
    cells: list[dict[str, Any]]
    structure_sha256: str
    cells_sha256: str
    mapping: dict[str, str]
    substituted: dict[str, int]
    dropped_block_entities: dict[str, int]


def _file_name(at: tuple[int, int, int]) -> str:
    return "cells/{}_{}_{}.json".format(*at)


def cut_cells(
    grid: np.ndarray, palette: list[str], low: tuple[int, int, int], bed_colours: dict[tuple[int, int, int], int],
) -> Iterator[tuple[tuple[int, int, int], dict[str, Any]]]:
    """Each non-air 16^3 cell of ``grid[x, y, z]`` as ``(corner, document)``, ``low`` its world position of ``grid[0, 0, 0]``.

    ``grid`` holds indexes into ``palette``, -1 for no state. ``bed_colours`` is keyed by world position.
    """
    airs = [i for i, name in enumerate(palette) if name == AIR]
    pad = tuple(low[a] % CELL for a in range(3))
    shape = tuple(-(-(grid.shape[a] + pad[a]) // CELL) * CELL for a in range(3))
    padded = np.full(shape, -1, dtype=np.int16)
    padded[pad[0] : pad[0] + grid.shape[0], pad[1] : pad[1] + grid.shape[1], pad[2] : pad[2] + grid.shape[2]] = grid
    origin = tuple(low[a] - pad[a] for a in range(3))
    solid = (padded >= 0) & ~np.isin(padded, airs)
    by_cell: dict[tuple[int, int, int], list[tuple[tuple[int, int, int], int]]] = {}
    for position, colour in bed_colours.items():
        by_cell.setdefault(tuple(v - v % CELL for v in position), []).append((position, colour))  # type: ignore[arg-type]
    cells = solid.reshape(shape[0] // CELL, CELL, shape[1] // CELL, CELL, shape[2] // CELL, CELL).any(axis=(1, 3, 5))
    for cx, cy, cz in np.argwhere(cells):
        at = (origin[0] + int(cx) * CELL, origin[1] + int(cy) * CELL, origin[2] + int(cz) * CELL)
        part = padded[cx * CELL : (cx + 1) * CELL, cy * CELL : (cy + 1) * CELL, cz * CELL : (cz + 1) * CELL]
        flat = np.ascontiguousarray(part.transpose(1, 2, 0)).reshape(-1)
        used, inverse = np.unique(flat, return_inverse=True)
        names = [palette[i] if i >= 0 else AIR for i in used.tolist()]
        merged = sorted(set(names))
        remap = np.array([merged.index(n) for n in names], dtype=np.int64)
        entities = [
            {"pos": [wx - at[0], wy - at[1], wz - at[2]], "color": colour}
            for (wx, wy, wz), colour in sorted(by_cell.get(at, []))
        ]
        doc: dict[str, Any] = {"palette": merged, "blocks": remap[inverse].tolist()}
        if entities:
            doc["block_entities"] = entities
        yield at, doc


class _Hashing:
    """A stream that hashes what it hands out, so the structure's sha256 costs no second read."""

    def __init__(self, stream: IO[bytes]) -> None:
        self._stream, self.digest = stream, hashlib.sha256()

    def read(self, n: int) -> bytes:
        data = self._stream.read(n)
        self.digest.update(data)
        return data

    def drain(self) -> str:
        while self.read(1 << 22):
            pass
        return self.digest.hexdigest()


def convert(source: Path, out: Path, spec: StructureSpec) -> Converted:
    """Cut ``source`` into cell files under ``out`` and write ``out/manifest.json``.

    Layer 0 is held as int16 for the cut, 93 MB for the pit, since the file lists its palette after its indexes.
    """
    layers: dict[int, np.ndarray] = {}

    def keep(layer: int, chunks: Iterator[tuple[int, np.ndarray]]) -> None:
        if layer == 0:
            parts = [chunk.astype(np.int16) for _, chunk in chunks]
            layers[0] = np.concatenate(parts) if parts else np.zeros(0, dtype=np.int16)
        else:
            layers[layer] = np.array([sum(int((chunk >= 0).sum()) for _, chunk in chunks)])

    with open_structure(source) as raw:
        stream = _Hashing(raw)
        structure = read_structure(stream, keep)  # type: ignore[arg-type]
        structure_sha256 = stream.drain()
    if set(layers) != {0, 1} or len(layers[0]) != structure.cells:
        raise StructureBuildError(f"layers {sorted(layers)} do not match a structure of {structure.cells} cells")
    if layers[1][0]:
        raise StructureBuildError(f"layer 1 holds {int(layers[1][0])} blocks; a waterlogged or second-layer block would be dropped")
    sx, sy, sz = structure.size
    counts = np.bincount(layers[0][layers[0] >= 0], minlength=len(structure.palette))
    palette = [spec.substitutes.get(state.name, state.key) for state in structure.palette]
    substituted: dict[str, int] = {}
    for state, count in zip(structure.palette, counts.tolist(), strict=True):
        if state.name in spec.substitutes and count:
            substituted[state.name] = substituted.get(state.name, 0) + count
    low = spec.world_min()
    bed_colours: dict[tuple[int, int, int], int] = {}
    dropped: dict[str, int] = {}
    for index, entity in structure.block_entities.items():
        kind = str(entity.get("id"))
        if kind != "Bed":
            dropped[kind] = dropped.get(kind, 0) + 1
            continue
        colour = entity.get("color")
        on = structure.palette[int(layers[0][index])].name
        if not isinstance(colour, int) or not 0 <= colour <= 15 or on != BED:
            raise StructureBuildError(f"bed block entity at index {index} has colour {colour!r} on {on}, not 0 to 15 on {BED}")
        x, rest = divmod(index, sy * sz)
        y, z = divmod(rest, sz)
        bed_colours[(low[0] + x, low[1] + y, low[2] + z)] = int(colour)
    cells: list[dict[str, Any]] = []
    digest = hashlib.sha256()
    for at, doc in cut_cells(layers[0].reshape(sx, sy, sz), palette, low, bed_colours):
        body = json.dumps(doc, separators=(",", ":"), sort_keys=True).encode()
        path = out / _file_name(at)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
        sha = hashlib.sha256(body).hexdigest()
        digest.update(f"{at[0]} {at[1]} {at[2]} {sha}\n".encode())
        cells.append({"file": _file_name(at), "sha256": sha, "at": list(at)})
    (out / MANIFEST).write_text(json.dumps({"cells": cells}, separators=(",", ":")), encoding="utf-8", newline="\n")
    return Converted(cells, structure_sha256, digest.hexdigest(), dict(spec.substitutes), substituted, dropped)


def load(bridge: Bridge, spec: StructureSpec, cells: list[dict[str, Any]], max_edge: int = DEFAULT_MAX_EDGE) -> None:
    """One ``load_structure`` job per batch; every chunk under ``cells`` must already be generated."""
    for group in batches(cells, max_edge):
        bridge.call_job("load_structure", world=spec.world, cells=group)


def batches(cells: list[dict[str, Any]], max_edge: int = DEFAULT_MAX_EDGE) -> list[list[dict[str, Any]]]:
    """``cells`` grouped so each group's bounding box has no edge over ``max_edge``, in position order."""
    span = max_edge // CELL
    groups: dict[tuple[int, int, int], list[dict[str, Any]]] = {}
    for cell in sorted(cells, key=lambda c: tuple(c["at"])):
        groups.setdefault(tuple(v // (span * CELL) for v in cell["at"]), []).append(cell)  # type: ignore[arg-type]
    return [groups[key] for key in sorted(groups)]
