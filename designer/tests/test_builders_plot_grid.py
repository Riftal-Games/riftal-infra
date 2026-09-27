import pytest

from designer.builders.base import Palette
from designer.builders.plot_grid import CLEARANCE, PlotGridSpec, build_plot_grid
from designer.edits import Fill
from designer.region import Bounds
from designer.verify import path_exists


@pytest.fixture
def palette() -> Palette:
    return Palette.load("mine_stone")


def _spec(**over) -> PlotGridSpec:
    data = {"name": "plots", "world": "design", "origin": [0, 0], "y": 10, "rows": 2, "cols": 2, "plot_size": [4, 4], "buffer": 2}
    data.update(over)
    return PlotGridSpec.from_dict(data)


def test_from_dict_rejects_a_missing_field() -> None:
    with pytest.raises(ValueError, match=r"missing \['plot_size'\]"):
        PlotGridSpec.from_dict({"name": "p", "world": "design", "origin": [0, 0], "y": 10, "rows": 1, "cols": 1})


@pytest.mark.parametrize("field, match", [("rows", "rows and cols"), ("cols", "rows and cols"), ("buffer", "buffer")])
def test_from_dict_rejects_a_non_positive_dimension(field: str, match: str) -> None:
    with pytest.raises(ValueError, match=f"{match} must be at least 1"):
        _spec(**{field: 0})


def test_plot_count_matches_rows_times_cols(palette: Palette) -> None:
    edits = build_plot_grid(_spec(rows=2, cols=3), palette)
    assert len(edits.extras["regions"]) == 6


def test_plots_do_not_overlap(palette: Palette) -> None:
    edits = build_plot_grid(_spec(), palette)
    boxes = [Bounds(tuple(r["min"]), tuple(r["max"])) for r in edits.extras["regions"]]
    for i, a in enumerate(boxes):
        for b in boxes[i + 1:]:
            assert a.intersect(b) is None


def test_region_is_tagged_plot_with_row_and_col(palette: Palette) -> None:
    edits = build_plot_grid(_spec(), palette)
    by_name = {r["name"]: r for r in edits.extras["regions"]}
    region = by_name["plots_1_0"]
    assert region["tags"] == ["plot"]
    assert region["meta"] == {"row": 1, "col": 0}
    assert (region["min"], region["max"]) == ([0, 10, 6], [3, 10, 9])


def test_plot_grid_extras_names_every_plot(palette: Palette) -> None:
    edits = build_plot_grid(_spec(), palette)
    assert edits.extras["plot_grid"] == {
        "rows": 2, "cols": 2,
        "plots": {"0,0": "plots_0_0", "0,1": "plots_0_1", "1,0": "plots_1_0", "1,1": "plots_1_1"},
    }


def test_air_cleared_above_the_whole_footprint(palette: Palette) -> None:
    edits = build_plot_grid(_spec(), palette)
    clears = [op for op in edits.ops if isinstance(op, Fill) and op.block == "minecraft:air"]
    assert len(clears) == 1
    assert clears[0].bounds == Bounds((0, 11, 0), (9, 10 + CLEARANCE, 9))


def test_build_plot_grid_is_deterministic(palette: Palette) -> None:
    spec = _spec()
    assert build_plot_grid(spec, palette).to_json() == build_plot_grid(spec, palette).to_json()


def test_path_exists_between_two_far_plots(palette: Palette) -> None:
    spec = _spec()
    edits = build_plot_grid(spec, palette)
    region = edits.to_region()
    found = path_exists(region, (1, spec.y + 1, 1), (7, spec.y + 1, 7))
    assert found.ok, found.detail
