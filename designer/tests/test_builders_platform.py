import pytest

from designer.builders.base import Palette
from designer.builders.platform import CLEARANCE, PlatformSpec, build_platform
from designer.edits import Fill
from designer.region import Bounds


@pytest.fixture
def palette() -> Palette:
    return Palette.load("mine_stone")


def _spec(**over) -> PlatformSpec:
    data = {"name": "landing", "world": "design", "min": [0, 0], "max": [4, 6], "y": 10}
    data.update(over)
    return PlatformSpec.from_dict(data)


def test_from_dict_rejects_a_missing_field() -> None:
    with pytest.raises(ValueError, match=r"missing \['y'\]"):
        PlatformSpec.from_dict({"name": "p", "world": "design", "min": [0, 0], "max": [1, 1]})


def test_floor_fills_the_footprint_at_y(palette: Palette) -> None:
    spec = _spec()
    edits = build_platform(spec, palette)
    floor = palette.block("floor")
    fills = [op for op in edits.ops if isinstance(op, Fill) and op.block == floor]
    assert len(fills) == 1
    assert fills[0].bounds == Bounds((0, 10, 0), (4, 10, 6))


def test_air_cleared_three_blocks_above_the_floor(palette: Palette) -> None:
    spec = _spec()
    edits = build_platform(spec, palette)
    clears = [op for op in edits.ops if isinstance(op, Fill) and op.block == "minecraft:air"]
    assert len(clears) == 1
    assert clears[0].bounds == Bounds((0, 11, 0), (4, 13, 6))
    assert clears[0].bounds.size[1] == CLEARANCE


def test_no_railing_by_default(palette: Palette) -> None:
    spec = _spec()
    edits = build_platform(spec, palette)
    slab = palette.block("slab")
    assert not any(isinstance(op, Fill) and op.block.startswith(slab) for op in edits.ops)


def test_railing_is_a_bottom_slab_ring_at_the_edge(palette: Palette) -> None:
    spec = _spec(railing=True)
    edits = build_platform(spec, palette)
    slab = palette.block("slab")
    ring = [op for op in edits.ops if isinstance(op, Fill) and op.block.startswith(slab)]
    assert len(ring) == 4
    assert all("minecraft:vertical_half=bottom" in op.block for op in ring)
    assert all(op.bounds.min[1] == op.bounds.max[1] == spec.y + 1 for op in ring)
    xs = {op.bounds.min[0] for op in ring} | {op.bounds.max[0] for op in ring}
    zs = {op.bounds.min[2] for op in ring} | {op.bounds.max[2] for op in ring}
    assert xs == {spec.footprint.min[0], spec.footprint.max[0]}
    assert zs == {spec.footprint.min[1], spec.footprint.max[1]}


def test_region_is_tagged_walkway(palette: Palette) -> None:
    spec = _spec()
    edits = build_platform(spec, palette)
    [region] = edits.extras["regions"]
    assert region["name"] == "landing"
    assert region["tags"] == ["walkway"]
    assert (region["min"], region["max"]) == ([0, 10, 0], [4, 10, 6])


def test_build_platform_is_deterministic(palette: Palette) -> None:
    spec = _spec(railing=True)
    assert build_platform(spec, palette).to_json() == build_platform(spec, palette).to_json()


@pytest.mark.parametrize("field", ["min", "max"])
def test_from_dict_rejects_a_fractional_coordinate(field: str) -> None:
    with pytest.raises(ValueError, match="min and max must be integers"):
        _spec(**{field: [-0.5, 6]})


def test_from_dict_rejects_a_fractional_y() -> None:
    with pytest.raises(ValueError, match="y must be an integer"):
        _spec(y=-0.5)
