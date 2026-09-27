"""``build_perimeter``: a striped boundary wall around a rectangle, as an ``EditList``."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from functools import reduce
from typing import Any

from designer.builders.base import Palette
from designer.edits import EditList, Fill
from designer.region import Bounds, Bounds2D, Heightmap
from designer.world_index import NamedRegion

Point2D = tuple[int, int]


@dataclass(frozen=True)
class PerimeterSpec:
    """A wall around ``footprint``'s edge, flush at ``y`` or riding a ``Heightmap``, a post every ``post_every``."""

    name: str
    world: str
    footprint: Bounds2D
    height: int
    y: int | None = None
    post_every: int = 8

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> PerimeterSpec:
        missing = [k for k in ("name", "world", "min", "max", "height") if k not in data]
        if missing:
            raise ValueError(f"perimeter spec is missing {missing}")
        try:
            footprint = Bounds2D(tuple(int(v) for v in data["min"]), tuple(int(v) for v in data["max"]))
            y = data.get("y")
            spec = cls(
                str(data["name"]), str(data["world"]), footprint, int(data["height"]),
                None if y is None else int(y), int(data.get("post_every", 8)),
            )
        except (TypeError, KeyError, IndexError) as e:
            raise ValueError(f"perimeter spec is malformed: {e!r}") from e
        spec.validate()
        return spec

    def validate(self) -> None:
        if min(self.height, self.post_every) < 1:
            raise ValueError("height and post_every must be at least 1")
        if self.footprint.min[0] == self.footprint.max[0] or self.footprint.min[1] == self.footprint.max[1]:
            raise ValueError(f"footprint {self.footprint.min}..{self.footprint.max} must span at least 2 blocks on both axes to close a loop")


def _ring_path(x0: int, x1: int, z0: int, z1: int) -> list[Point2D]:
    """Every cell of the rectangle's edge, once each, walked clockwise from the north-west corner."""
    top = [(x, z0) for x in range(x0, x1 + 1)]
    right = [(x1, z) for z in range(z0 + 1, z1 + 1)]
    bottom = [(x, z1) for x in range(x1 - 1, x0 - 1, -1)]
    left = [(x0, z) for z in range(z1 - 1, z0, -1)]
    return top + right + bottom + left


def build_perimeter(spec: PerimeterSpec, palette: Palette, hm: Heightmap | None = None) -> EditList:
    """A ring of alternating ``boundary``/``boundary_accent`` columns, flush at ``spec.y`` or, given ``hm``,
    starting one block above the ground, ``build_road``'s convention. A post at every corner and every
    ``spec.post_every``'th step stands one block taller, always ``boundary_accent``."""
    if spec.y is None and hm is None:
        raise ValueError("perimeter follows the terrain but no heightmap was given")
    (x0, z0), (x1, z1) = spec.footprint.min, spec.footprint.max
    path = _ring_path(x0, x1, z0, z1)
    corners = {(x0, z0), (x1, z0), (x1, z1), (x0, z1)}
    boundary, accent = palette.block("boundary"), palette.block("boundary_accent")
    ops: list[Fill] = []
    for i, (x, z) in enumerate(path):
        base = spec.y if spec.y is not None else hm.height(x, z) + 1
        post = (x, z) in corners or i % spec.post_every == 0
        top = base + spec.height - 1 + (1 if post else 0)
        block = accent if post or i % 2 else boundary
        ops.append(Fill(Bounds((x, base, z), (x, top, z)), block))
    box = reduce(Bounds.union, (op.bounds for op in ops))
    region = NamedRegion(spec.name, spec.world, box.min, box.max, ["pvp_boundary"], {"visible": True})
    return EditList(spec.world, ops, {"regions": [region.to_json()]})
