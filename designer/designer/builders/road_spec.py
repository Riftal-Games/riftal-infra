"""A road's spec: a centre line from ``start`` to ``end`` that ``road.py`` profiles and paves."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from designer.coords import int_coords, whole_int

STYLES = ("straight", "manhattan")
Point = tuple[int, int]


def _run(a: int, b: int) -> list[int]:
    """Every integer from ``a`` to ``b`` inclusive, ascending or descending."""
    step = 1 if b >= a else -1
    return list(range(a, b + step, step))


@dataclass(frozen=True)
class RoadSpec:
    name: str
    world: str
    start: Point
    end: Point
    width: int = 3
    clear_height: int = 4
    edge: bool = False
    style: str = "manhattan"

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> RoadSpec:
        missing = [k for k in ("name", "world", "start", "end") if k not in data]
        if missing:
            raise ValueError(f"road spec is missing {missing}")
        try:
            spec = cls(
                str(data["name"]), str(data["world"]),
                *(int_coords((data[k][0], data[k][1]), "start and end must be integers") for k in ("start", "end")),
                whole_int(data.get("width", 3), "width must be an integer"),
                whole_int(data.get("clear_height", 4), "clear_height must be an integer"),
                bool(data.get("edge", False)), str(data.get("style", "manhattan")),
            )
        except (TypeError, KeyError, IndexError) as e:
            raise ValueError(f"road spec is malformed: {e!r}") from e
        spec.validate()
        return spec

    def validate(self) -> None:
        if self.style not in STYLES:
            raise ValueError(f"style must be one of {STYLES}, got {self.style!r}")
        if self.width < 1:
            raise ValueError(f"width must be at least 1, got {self.width}")
        if self.clear_height < 1:
            raise ValueError(f"clear_height must be at least 1, got {self.clear_height}")
        if self.start == self.end:
            raise ValueError(f"start and end must differ, both are {self.start}")
        shares_axis = self.start[0] == self.end[0] or self.start[1] == self.end[1]
        if self.style == "straight" and not shares_axis:
            raise ValueError(f"a straight road needs start and end to share x or z, got {self.start} and {self.end}")

    def centre_line(self) -> list[Point]:
        """Waypoints from ``start`` to ``end`` inclusive, one block apart: a single run on a shared axis, else an
        x-then-z dogleg for ``manhattan``."""
        (x0, z0), (x1, z1) = self.start, self.end
        leg_x = [(x, z0) for x in _run(x0, x1)]
        leg_z = [(x1, z) for z in _run(z0, z1)][1:]
        return leg_x + leg_z
