import numpy as np
import pytest

from designer.blocks import AIR
from designer.region import EMPTY_Y, Bounds, Bounds2D, Heightmap, Region, heightmap_from_region
from designer.terrain import analyze_terrain, find_flat_site, slope_map, terraform

WORLD = "t"
STONE = "minecraft:stone"


def _heightmap(bounds: Bounds2D, heights: np.ndarray) -> Heightmap:
    top = np.where(heights != EMPTY_Y, 1, 0).astype(np.int16)
    return Heightmap(WORLD, bounds, heights.astype(np.int16), top, [AIR, STONE])


def _base(hm: Heightmap, ceiling: int) -> Region:
    """Solid ground up to each column's height, air above, over the whole heightmap."""
    (x0, z0), (x1, z1) = hm.bounds.min, hm.bounds.max
    region = Region.empty(hm.world, Bounds((x0, 0, z0), (x1, ceiling, z1)))
    for x in range(x0, x1 + 1):
        for z in range(z0, z1 + 1):
            h = hm.height(x, z)
            if h >= 0:
                region.fill(Bounds((x, 0, z), (x, h, z)), STONE)
    return region


def test_slope_map_reads_the_ramp_steps_and_the_flat_plateau(ramp_region: Region) -> None:
    hm = heightmap_from_region(ramp_region)
    slope = slope_map(hm)
    assert slope[0].tolist() == [0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 2, 2, 0, 0, 0, 0, 0]
    assert (slope == slope[0]).all()


def test_slope_map_ignores_a_neighbour_outside_the_map() -> None:
    hm = _heightmap(Bounds2D((0, 0), (2, 0)), np.array([[5, 5, 5]]))
    assert slope_map(hm).tolist() == [[0, 0, 0]]
    isolated = _heightmap(Bounds2D((0, 0), (0, 0)), np.array([[5]]))
    assert slope_map(isolated).tolist() == [[-1]]


def test_analyze_terrain_stats_on_the_ramp_fixture(ramp_region: Region) -> None:
    hm = heightmap_from_region(ramp_region)
    stats = analyze_terrain(hm, flat_slope=0)
    assert stats.columns == 300 and stats.min == 0 and stats.max == 9
    assert stats.mean == pytest.approx(4.6)
    assert stats.water_fraction == 0.0
    assert stats.flat_fraction == pytest.approx(140 / 300)
    assert analyze_terrain(hm, flat_slope=1).flat_fraction == pytest.approx(280 / 300)


def test_analyze_terrain_on_an_empty_heightmap_is_all_none() -> None:
    empty = _heightmap(Bounds2D((0, 0), (3, 3)), np.full((4, 4), EMPTY_Y))
    stats = analyze_terrain(empty)
    assert stats.columns == 0
    assert (stats.min, stats.max, stats.mean, stats.water_fraction, stats.flat_fraction) == (None, None, None, None, None)


def test_analyze_terrain_rejects_a_negative_flat_slope() -> None:
    hm = _heightmap(Bounds2D((0, 0), (1, 0)), np.array([[1, 1]]))
    with pytest.raises(ValueError, match="flat_slope"):
        analyze_terrain(hm, flat_slope=-1)


def _plateaus() -> Heightmap:
    """A steep ramp with two flat 6x6 plateaus at x=10..15 and x=28..33; only their inner 4x4 columns are flat."""
    nx, nz = 40, 10
    heights = np.zeros((nz, nx), dtype=np.int64)
    for x in range(nx):
        heights[:, x] = x * 5
    heights[:, 10:16] = 200
    heights[:, 28:34] = 200
    return _heightmap(Bounds2D((0, 0), (nx - 1, nz - 1)), heights)


def test_find_flat_site_picks_the_plateau_nearest_near() -> None:
    hm = _plateaus()
    near_a = find_flat_site(hm, 4, max_slope=0, max_range=0, near=(11, 0, 5), limit=1)
    assert len(near_a) == 1 and (near_a[0].bounds.min[0], near_a[0].bounds.max[0]) == (11, 14)
    near_b = find_flat_site(hm, 4, max_slope=0, max_range=0, near=(33, 0, 5), limit=1)
    assert (near_b[0].bounds.min[0], near_b[0].bounds.max[0]) == (29, 32)
    assert near_a[0].height == 200 and near_b[0].height == 200
    assert near_a[0].range == 0 and near_a[0].slope_max == 0 and near_a[0].water_fraction == 0.0


def test_find_flat_site_without_near_ranks_by_score() -> None:
    hm = _plateaus()
    sites = find_flat_site(hm, 4, max_slope=0, max_range=0, limit=50)
    assert sites and all(s.score == 0.0 for s in sites)
    assert {s.bounds.min[0] for s in sites} == {11, 29}


def test_find_flat_site_suppression_thins_heavily_overlapping_windows() -> None:
    hm = _heightmap(Bounds2D((0, 0), (5, 9)), np.full((10, 6), 50))
    raw = find_flat_site(hm, 4, max_slope=0, max_range=0, limit=100, suppress=0)
    thinned = find_flat_site(hm, 4, max_slope=0, max_range=0, limit=100, suppress=4)
    assert len(raw) == 21
    assert 1 <= len(thinned) < len(raw)


def test_find_flat_site_max_water_excludes_a_window_touching_the_pond() -> None:
    heights = np.full((4, 8), 10, dtype=np.int64)
    top = np.ones((4, 8), dtype=np.int16)
    top[:, 4] = 2
    hm = Heightmap(WORLD, Bounds2D((0, 0), (7, 3)), heights.astype(np.int16), top, [AIR, STONE, "minecraft:water"])
    dry = find_flat_site(hm, 4, max_slope=0, max_range=0, max_water=0.0)
    assert [s.bounds.min[0] for s in dry] == [0] and dry[0].bounds.max[0] == 3
    wet_ok = find_flat_site(hm, 4, max_slope=0, max_range=0, max_water=0.3, limit=50, suppress=0)
    assert any(s.bounds.min[0] == 1 for s in wet_ok) and any(s.water_fraction > 0 for s in wet_ok)


def test_find_flat_site_validates_size_and_thresholds() -> None:
    hm = _heightmap(Bounds2D((0, 0), (9, 9)), np.full((10, 10), 5))
    with pytest.raises(ValueError, match="size must be at least 1"):
        find_flat_site(hm, 0)
    with pytest.raises(ValueError, match="smaller than site size"):
        find_flat_site(hm, 20)
    with pytest.raises(ValueError, match="at least 0"):
        find_flat_site(hm, 2, max_range=-1)
    with pytest.raises(ValueError, match="at least 1"):
        find_flat_site(hm, 2, limit=0)


def test_terraform_flatten_yields_a_flat_heightmap_after_to_region(ramp_region: Region) -> None:
    hm = heightmap_from_region(ramp_region)
    edits = terraform(hm, hm.bounds, mode="flatten", level=5)
    assert edits.extras["terrain_mode"] == "flatten" and edits.extras["columns"] > 0
    flattened = heightmap_from_region(edits.to_region(base=ramp_region))
    assert set(np.unique(flattened.heights).tolist()) == {5}


def test_terraform_raise_only_builds_up_and_lower_only_cuts_down() -> None:
    hm = _heightmap(Bounds2D((0, 0), (9, 0)), np.array([[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]]))
    base = _base(hm, ceiling=12)

    raised = terraform(hm, hm.bounds, mode="raise", level=4, block=STONE)
    heights = heightmap_from_region(raised.to_region(base=base)).heights[0]
    assert heights.tolist() == [4, 4, 4, 4, 4, 5, 6, 7, 8, 9]

    lowered = terraform(hm, hm.bounds, mode="lower", level=4)
    heights = heightmap_from_region(lowered.to_region(base=base)).heights[0]
    assert heights.tolist() == [0, 1, 2, 3, 4, 4, 4, 4, 4, 4]


def test_terraform_coalesces_a_flat_plateau_into_one_fill_but_never_merges_differing_spans() -> None:
    flat = _heightmap(Bounds2D((0, 0), (5, 5)), np.zeros((6, 6)))
    raised = terraform(flat, flat.bounds, mode="raise", level=4, block=STONE)
    assert len(raised.ops) == 1 and raised.ops[0].bounds.to_json() == {"min": [0, 1, 0], "max": [5, 4, 5]}

    ramp = _heightmap(Bounds2D((0, 0), (9, 0)), np.array([[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]]))
    varied = terraform(ramp, ramp.bounds, mode="raise", level=4, block=STONE)
    # every column below level 4 needs a different fill span; none share one
    assert len(varied.ops) == 4


def test_terraform_coalesces_a_run_but_splits_across_an_unchanged_row() -> None:
    heights = np.zeros((5, 4), dtype=np.int64)
    heights[2, :] = 3
    hm = _heightmap(Bounds2D((0, 0), (3, 4)), heights)
    edits = terraform(hm, hm.bounds, mode="raise", level=3, block=STONE)
    boxes = sorted((op.bounds.min, op.bounds.max) for op in edits.ops)
    assert boxes == [((0, 1, 0), (3, 3, 1)), ((0, 1, 3), (3, 3, 4))]


def test_terraform_smooth_pulls_a_spike_toward_its_neighbours() -> None:
    heights = np.zeros((5, 5), dtype=np.int64)
    heights[2, 2] = 10
    hm = _heightmap(Bounds2D((0, 0), (4, 4)), heights)
    base = _base(hm, ceiling=10)
    smoothed = heightmap_from_region(terraform(hm, hm.bounds, mode="smooth", smooth_radius=1, block=STONE).to_region(base=base))
    assert smoothed.height(2, 2) == 1
    assert smoothed.height(0, 0) == 0


def test_terraform_feathering_blends_the_edge_and_matches_the_interior_beyond_it() -> None:
    nx, nz = 20, 10
    heights = np.zeros((nz, nx), dtype=np.int64)
    for x in range(nx):
        heights[:, x] = x // 4
    hm = _heightmap(Bounds2D((0, 0), (nx - 1, nz - 1)), heights)
    base = _base(hm, ceiling=10)

    unfeathered = heightmap_from_region(terraform(hm, hm.bounds, mode="flatten", level=2).to_region(base=base)).heights[5]
    feather2 = heightmap_from_region(terraform(hm, hm.bounds, mode="flatten", level=2, feather=2).to_region(base=base)).heights[5]
    feather4 = heightmap_from_region(terraform(hm, hm.bounds, mode="flatten", level=2, feather=4).to_region(base=base)).heights[5]

    assert unfeathered.tolist() == [2] * nx
    assert feather2.tolist() == [0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 4]
    assert feather4.tolist() == [0, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 4, 4]
    # beyond the feather distance from the bounds edge, every feather value gives the same interior columns
    assert feather2[4:16].tolist() == feather4[4:16].tolist() == unfeathered[4:16].tolist()


def test_terraform_validates_mode_feather_smooth_radius_and_bounds() -> None:
    hm = _heightmap(Bounds2D((0, 0), (9, 0)), np.full((1, 10), 5))
    with pytest.raises(ValueError, match="mode must be one of"):
        terraform(hm, hm.bounds, mode="dig")
    with pytest.raises(ValueError, match="feather must be at least 0"):
        terraform(hm, hm.bounds, mode="flatten", feather=-1)
    with pytest.raises(ValueError, match="smooth_radius must be at least 1"):
        terraform(hm, hm.bounds, mode="smooth", smooth_radius=0)
    with pytest.raises(ValueError, match="are not covered by the fetched heightmap"):
        terraform(hm, Bounds2D((0, 0), (20, 0)), mode="flatten")


def test_terraform_leaves_an_empty_column_alone() -> None:
    hm = _heightmap(Bounds2D((0, 0), (1, 0)), np.array([[EMPTY_Y, 3]]))
    edits = terraform(hm, hm.bounds, mode="flatten", level=5)
    assert edits.extras["columns"] == 1
    assert [op.bounds.min[0] for op in edits.ops] == [1]
