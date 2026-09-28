import pytest

from designer.builders.base import DIRS, Palette
from designer.builders.stairs import HEADROOM, StairsSpec, build_stairs
from designer.edits import Fill
from designer.region import Bounds, Region
from designer.verify import path_exists


@pytest.fixture
def palette() -> Palette:
    return Palette.load("mine_stone")


def _spec(**over) -> StairsSpec:
    data = {"world": "design", "from": [0, 0, 0], "direction": "east", "rise": 5, "width": 1}
    data.update(over)
    return StairsSpec.from_dict(data)


def test_from_dict_rejects_a_missing_field() -> None:
    with pytest.raises(ValueError, match=r"missing \['rise'\]"):
        StairsSpec.from_dict({"world": "design", "from": [0, 0, 0], "direction": "east"})


def test_from_dict_rejects_an_unknown_direction() -> None:
    with pytest.raises(ValueError, match="direction must be one of"):
        StairsSpec.from_dict({"world": "design", "from": [0, 0, 0], "direction": "up", "rise": 3})


@pytest.mark.parametrize("field, value", [("rise", 0), ("width", 0)])
def test_from_dict_rejects_a_non_positive_dimension(field: str, value: int) -> None:
    data = {"world": "design", "from": [0, 0, 0], "direction": "east", "rise": 3, "width": 1, field: value}
    with pytest.raises(ValueError, match=f"{field} must be at least 1"):
        StairsSpec.from_dict(data)


def test_one_stairs_row_per_rise_step(palette: Palette) -> None:
    spec = _spec(rise=5)
    edits = build_stairs(spec, palette)
    stairs_block = palette.block("stairs")
    rows = [op for op in edits.ops if isinstance(op, Fill) and op.block.startswith(stairs_block)]
    assert len(rows) == spec.rise
    assert {op.bounds.min[0] for op in rows} == set(range(1, spec.rise + 1))
    assert {op.bounds.min[1] for op in rows} == set(range(1, spec.rise + 1))
    # width=1: one block per row
    assert all(op.bounds.min == op.bounds.max for op in rows)


@pytest.mark.parametrize("direction, weirdo", [("east", 0), ("west", 1), ("south", 2), ("north", 3)])
def test_stairs_face_the_ascent(palette: Palette, direction: str, weirdo: int) -> None:
    spec = _spec(direction=direction, rise=2)
    edits = build_stairs(spec, palette)
    stairs_block = palette.block("stairs")
    rows = [op for op in edits.ops if isinstance(op, Fill) and op.block.startswith(stairs_block)]
    assert rows and all(f"weirdo_direction={weirdo}" in op.block for op in rows)


def test_support_fills_close_the_gap_down_to_the_base(palette: Palette) -> None:
    spec = _spec(rise=4)
    edits = build_stairs(spec, palette)
    wall = palette.block("wall")
    supports = [op for op in edits.ops if isinstance(op, Fill) and op.block == wall]
    assert len(supports) == spec.rise
    assert {op.bounds.min[1] for op in supports} == {spec.base[1]}
    assert {op.bounds.max[1] for op in supports} == {spec.base[1] + i - 1 for i in range(1, spec.rise + 1)}


def test_headroom_cleared_above_every_row(palette: Palette) -> None:
    spec = _spec(rise=3)
    edits = build_stairs(spec, palette)
    clears = [op for op in edits.ops if isinstance(op, Fill) and op.block == "minecraft:air"]
    assert len(clears) == spec.rise
    for i, op in enumerate(sorted(clears, key=lambda o: o.bounds.min[0]), start=1):
        assert (op.bounds.min[1], op.bounds.max[1]) == (spec.base[1] + i + 1, spec.base[1] + i + HEADROOM)


def test_width_widens_every_row(palette: Palette) -> None:
    spec = _spec(width=3)
    edits = build_stairs(spec, palette)
    stairs_block = palette.block("stairs")
    rows = [op for op in edits.ops if isinstance(op, Fill) and op.block.startswith(stairs_block)]
    # "east" travel widens across z
    assert all(op.bounds.size[2] == 3 for op in rows)


def test_build_stairs_is_deterministic(palette: Palette) -> None:
    spec = _spec()
    assert build_stairs(spec, palette).to_json() == build_stairs(spec, palette).to_json()


def test_path_exists_climbs_from_the_base_to_the_top(palette: Palette) -> None:
    spec = _spec(rise=6, width=1)
    edits = build_stairs(spec, palette)

    landing = Bounds(spec.base, spec.base)
    box = landing.union(edits.bounds).expand(2, "xz").expand(HEADROOM + 1, "y")
    base_region = Region.empty(spec.world, box)
    base_region.fill(landing, palette.block("floor"))
    region = edits.to_region(base=base_region)

    dx, dz = DIRS[spec.direction]
    bottom = (spec.base[0], spec.base[1] + 1, spec.base[2])
    top = (spec.base[0] + dx * spec.rise, spec.base[1] + spec.rise + 1, spec.base[2] + dz * spec.rise)

    found = path_exists(region, bottom, top)
    assert found.ok, found.detail


def test_from_dict_rejects_a_fractional_coordinate() -> None:
    with pytest.raises(ValueError, match="from must be three integers"):
        _spec(**{"from": [-0.5, 0, 0]})


@pytest.mark.parametrize("field", ["rise", "width"])
def test_from_dict_rejects_a_fractional_size(field: str) -> None:
    with pytest.raises(ValueError, match=rf"^{field} must be an integer, got 2\.5$"):
        _spec(**{field: 2.5})
