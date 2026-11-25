"""Builders: pure functions from a spec to an ``EditList``. Holds ``mine_spec``, the mine spec and geometry ``mine_valid`` reads."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from designer.builders.base import Palette
from designer.builders.hall import HallSpec, build_hall
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.builders.perimeter import PerimeterSpec, build_perimeter
from designer.builders.platform import PlatformSpec, build_platform
from designer.builders.plot_grid import PlotGridSpec, build_plot_grid
from designer.builders.road import build_road
from designer.builders.road_spec import RoadSpec
from designer.builders.room import RoomSpec, build_room
from designer.builders.signage import SignageSpec, build_signage
from designer.builders.stairs import StairsSpec, build_stairs
from designer.edits import EditList
from designer.region import Bounds2D, Heightmap

# A world name and the bounds a builder needs ground for, answered with the
# ``Heightmap`` over them. Bound to a bridge by the CLI or MCP entry point,
# so a builder never has to know how the fetch happens, only what it needs.
HeightmapFetch = Callable[[str, Bounds2D], Heightmap]


def _road_bounds(spec: RoadSpec) -> Bounds2D:
    """The heightmap footprint a road spec implies: its centre line's bounding box."""
    xs, zs = zip(*spec.centre_line(), strict=True)
    return Bounds2D((min(xs), min(zs)), (max(xs), max(zs)))


def _build_road(spec: dict[str, Any], palette: Palette, fetch: HeightmapFetch) -> EditList:
    road_spec = RoadSpec.from_dict(spec)
    return build_road(road_spec, palette, fetch(road_spec.world, _road_bounds(road_spec)))


def _build_perimeter(spec: dict[str, Any], palette: Palette, fetch: HeightmapFetch) -> EditList:
    perimeter_spec = PerimeterSpec.from_dict(spec)
    hm = None if perimeter_spec.y is not None else fetch(perimeter_spec.world, perimeter_spec.footprint)
    return build_perimeter(perimeter_spec, palette, hm)


# Kind name to the builder that turns its spec dict into an ``EditList``. A
# builder's own function typically wants its dataclass, not the raw dict, so
# the entry here is the thing that closes over that conversion. Every entry
# takes a ``HeightmapFetch`` alongside the spec and palette, whether or not
# it needs real terrain, so one registry and one call site serve every
# builder. Each builder issue adds its own entry.
BUILDERS: dict[str, Callable[[dict[str, Any], Palette, HeightmapFetch], EditList]] = {
    "mine": lambda spec, palette, fetch: build_mine(MineSpec.from_dict(spec), palette),
    "road": _build_road,
    "stairs": lambda spec, palette, fetch: build_stairs(StairsSpec.from_dict(spec), palette),
    "platform": lambda spec, palette, fetch: build_platform(PlatformSpec.from_dict(spec), palette),
    "plot_grid": lambda spec, palette, fetch: build_plot_grid(PlotGridSpec.from_dict(spec), palette),
    "signage": lambda spec, palette, fetch: build_signage(SignageSpec.from_dict(spec)),
    "perimeter": _build_perimeter,
    "hall": lambda spec, palette, fetch: build_hall(HallSpec.from_dict(spec), palette),
    "room": lambda spec, palette, fetch: build_room(RoomSpec.from_dict(spec), palette),
}
