"""``build_plot_grid``: a grid of flush plot outlines joined by road, as an ``EditList``."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from functools import reduce
from typing import Any

from designer.blocks import AIR
from designer.builders.base import Palette
from designer.coords import int_coord, int_coords
from designer.edits import EditList, Fill
from designer.region import Bounds
from designer.world_index import NamedRegion

Point2D = tuple[int, int]

# Headroom above the flush floor a stand check needs: the floor itself plus
# one cell each for feet and head, the same minimum ``stairs.HEADROOM`` relies on.
CLEARANCE = 2


@dataclass(frozen=True)
class PlotGridSpec:
    """``rows`` by ``cols`` plots of ``plot_size`` at ``origin``, flush at ``y``, ``buffer`` of road apart."""

    name: str
    world: str
    origin: Point2D
    y: int
    rows: int
    cols: int
    plot_size: tuple[int, int]
    buffer: int = 3

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> PlotGridSpec:
        missing = [k for k in ("name", "world", "origin", "y", "rows", "cols", "plot_size") if k not in data]
        if missing:
            raise ValueError(f"plot grid spec is missing {missing}")
        try:
            spec = cls(
                str(data["name"]), str(data["world"]),
                int_coords((data["origin"][0], data["origin"][1]), "origin must be integers"),
                int_coord(data["y"], "y must be an integer"), int(data["rows"]), int(data["cols"]),
                (int(data["plot_size"][0]), int(data["plot_size"][1])), int(data.get("buffer", 3)),
            )
        except (TypeError, KeyError, IndexError) as e:
            raise ValueError(f"plot grid spec is malformed: {e!r}") from e
        spec.validate()
        return spec

    def validate(self) -> None:
        if self.rows < 1 or self.cols < 1:
            raise ValueError(f"rows and cols must be at least 1, got {self.rows}x{self.cols}")
        if min(self.plot_size) < 1:
            raise ValueError(f"plot_size must be at least 1 on both axes, got {tuple(self.plot_size)!r}")
        if self.buffer < 1:
            raise ValueError(f"buffer must be at least 1, got {self.buffer}")

    def plot_bounds(self, row: int, col: int) -> Bounds:
        """The footprint of plot ``(row, col)``, one layer thick, flush at ``y``. ``buffer`` keeps every
        plot's ring off its neighbours', so plots never touch or overlap."""
        sx, sz = self.plot_size
        x0 = self.origin[0] + col * (sx + self.buffer)
        z0 = self.origin[1] + row * (sz + self.buffer)
        return Bounds((x0, self.y, z0), (x0 + sx - 1, self.y, z0 + sz - 1))


def _ring(box: Bounds, block: str) -> list[Fill]:
    """A one-block ring of ``block`` around ``box``'s edge, one ``Fill`` per side."""
    (x0, y, z0), (x1, _, z1) = box.min, box.max
    return [
        Fill(Bounds((x0, y, z0), (x1, y, z0)), block), Fill(Bounds((x0, y, z1), (x1, y, z1)), block),
        Fill(Bounds((x0, y, z0), (x0, y, z1)), block), Fill(Bounds((x1, y, z0), (x1, y, z1)), block),
    ]


def build_plot_grid(spec: PlotGridSpec, palette: Palette) -> EditList:
    """Roads across the whole grid footprint, each plot ringed by ``plot_edge`` so its outline reads flush at
    ``spec.y`` with nothing raised.

    The plots world layout is not built here: a plot's interior is left as road, same as its buffer, until the
    M5 brainstorm decides what stands on one. One region per plot is indexed, tagged ``plot``, with its row and
    column in ``meta``; ``extras.plot_grid`` names every plot by ``"row,col"`` for that later layout to read.
    """
    road, edge = palette.block("road"), palette.block("plot_edge")
    boxes = {(r, c): spec.plot_bounds(r, c) for r in range(spec.rows) for c in range(spec.cols)}
    footprint = reduce(Bounds.union, boxes.values())
    air = Bounds((footprint.min[0], spec.y + 1, footprint.min[2]), (footprint.max[0], spec.y + CLEARANCE, footprint.max[2]))

    ops: list[Fill] = [Fill(footprint, road), Fill(air, AIR)]
    regions, plots = [], {}
    for (r, c), box in sorted(boxes.items()):
        name = f"{spec.name}_{r}_{c}"
        ops.extend(_ring(box, edge))
        regions.append(NamedRegion(name, spec.world, box.min, box.max, ["plot"], {"row": r, "col": c}).to_json())
        plots[f"{r},{c}"] = name

    extras = {"regions": regions, "plot_grid": {"rows": spec.rows, "cols": spec.cols, "plots": plots}}
    return EditList(spec.world, ops, extras)
