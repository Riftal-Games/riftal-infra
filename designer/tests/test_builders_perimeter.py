import numpy as np
import pytest

from designer.blocks import BlockClass
from designer.builders.base import Palette
from designer.builders.perimeter import PerimeterSpec, build_perimeter
from designer.region import Bounds2D, Heightmap


@pytest.fixture
def palette() -> Palette:
    return Palette.load("mine_stone")


def _spec(**over) -> PerimeterSpec:
    data = {"name": "yard_boundary", "world": "design", "min": [0, 0], "max": [8, 6], "height": 3, "y": 10, "post_every": 4}
    data.update(over)
    return PerimeterSpec.from_dict(data)


def _flood(passable: np.ndarray, start: tuple[int, int]) -> set[tuple[int, int]]:
    """Four-connected cells of ``passable`` reachable from ``start``."""
    seen, stack = {start}, [start]
    while stack:
        z, x = stack.pop()
        for at in ((z + 1, x), (z - 1, x), (z, x + 1), (z, x - 1)):
            if all(0 <= v < n for v, n in zip(at, passable.shape)) and passable[at] and at not in seen:
                seen.add(at)
                stack.append(at)
    return seen


def test_from_dict_rejects_a_missing_field() -> None:
    with pytest.raises(ValueError, match=r"missing \['height'\]"):
        PerimeterSpec.from_dict({"name": "p", "world": "design", "min": [0, 0], "max": [8, 6]})


@pytest.mark.parametrize("over, match", [
    ({"height": 0}, "height and post_every must be at least 1"),
    ({"post_every": 0}, "height and post_every must be at least 1"),
    ({"min": [0, 0], "max": [0, 6]}, "must span at least 2 blocks"),
])
def test_from_dict_rejects_bad_dimensions(over: dict, match: str) -> None:
    with pytest.raises(ValueError, match=match):
        _spec(**over)


def test_build_perimeter_needs_a_heightmap_when_y_is_unset() -> None:
    with pytest.raises(ValueError, match="no heightmap was given"):
        build_perimeter(_spec(y=None), Palette.load("mine_stone"))


def test_region_is_tagged_pvp_boundary_and_visible_and_edits_apply_onto_their_own_bounds(palette: Palette) -> None:
    edits = build_perimeter(_spec(), palette)
    [region] = edits.extras["regions"]
    assert region["name"] == "yard_boundary" and region["tags"] == ["pvp_boundary"] and region["meta"] == {"visible": True}
    region_built = edits.to_region()
    assert (region_built.bounds.min, region_built.bounds.max) == (edits.bounds.min, edits.bounds.max)


def test_posts_are_one_taller_at_corners_and_the_wall_between_them_alternates(palette: Palette) -> None:
    spec = _spec(post_every=1000)
    edits = build_perimeter(spec, palette)
    boundary, accent = palette.block("boundary"), palette.block("boundary_accent")
    by_pos = {(op.bounds.min[0], op.bounds.min[2]): op for op in edits.ops}
    (x0, z0), (x1, z1) = spec.footprint.min, spec.footprint.max
    wall_top, post_top = spec.y + spec.height - 1, spec.y + spec.height
    for corner in ((x0, z0), (x1, z0), (x1, z1), (x0, z1)):
        assert by_pos[corner].bounds.max[1] == post_top and by_pos[corner].block == accent
    assert by_pos[(x0 + 1, z0)].bounds.max[1] == wall_top
    assert {by_pos[(x0 + 1, z0)].block, by_pos[(x0 + 2, z0)].block} == {boundary, accent}


def test_perimeter_is_closed_by_a_flood_fill_at_its_base(palette: Palette) -> None:
    edits = build_perimeter(_spec(), palette)
    layer = edits.to_region().classes()[0]
    passable = (layer == BlockClass.AIR) | (layer == BlockClass.PASSABLE)
    reach = _flood(passable, (1, 1))
    nz, nx = passable.shape
    assert reach == set(map(tuple, np.argwhere(passable)))
    assert not any(z in (0, nz - 1) or x in (0, nx - 1) for z, x in reach)


def test_perimeter_follows_the_terrain_when_y_is_unset(palette: Palette) -> None:
    spec = _spec(y=None)
    bounds = spec.footprint
    heights = np.arange(bounds.shape[0] * bounds.shape[1], dtype=np.int16).reshape(bounds.shape) + 5
    hm = Heightmap("design", Bounds2D(bounds.min, bounds.max), heights)
    edits = build_perimeter(spec, palette, hm)
    (x0, z0) = spec.footprint.min
    col = next(op for op in edits.ops if op.bounds.min[0] == x0 and op.bounds.min[2] == z0)
    assert col.bounds.min[1] == hm.height(x0, z0) + 1


def test_build_perimeter_is_deterministic(palette: Palette) -> None:
    spec = _spec()
    assert build_perimeter(spec, palette).to_json() == build_perimeter(spec, palette).to_json()


@pytest.mark.parametrize("field", ["min", "max"])
def test_from_dict_rejects_a_fractional_coordinate(field: str) -> None:
    with pytest.raises(ValueError, match="min and max must be integers"):
        _spec(**{field: [-0.5, 6]})


def test_from_dict_rejects_a_fractional_y() -> None:
    with pytest.raises(ValueError, match="y must be an integer"):
        _spec(y=-0.5)


@pytest.mark.parametrize("field", ["height", "post_every"])
def test_from_dict_rejects_a_fractional_size_or_count(field: str) -> None:
    with pytest.raises(ValueError, match=rf"^{field} must be an integer, got 2\.5$"):
        _spec(**{field: 2.5})
