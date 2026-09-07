from datetime import datetime

import numpy as np

from designer.blocks import AIR
from designer.config import REPORTS_DIR
from designer.region import Bounds2D, Heightmap
from designer.render import RAMP, Marker, ascii_heightmap, markers_from_index, report_path, summary
from designer.world_index import Location, NamedRegion, WorldEntry, WorldIndex

WORLD = "design"
STONE, WATER = "minecraft:stone", "minecraft:water"


def _heightmap(bounds: Bounds2D, heights: np.ndarray, top: np.ndarray | None = None) -> Heightmap:
    palette = [AIR, STONE, WATER]
    top = np.where(heights >= 0, 1, 0) if top is None else top
    return Heightmap(WORLD, bounds, heights.astype(np.int16), top.astype(np.int16), palette)


def _rows(text: str, width: int) -> list[str]:
    return [line[-width:] for line in text.splitlines()[2:]]


def test_wide_heightmap_is_downsampled_to_the_width_bound() -> None:
    bounds = Bounds2D((0, 0), (299, 299))
    zs, xs = np.mgrid[0:300, 0:300]
    text = ascii_heightmap(_heightmap(bounds, 40 + xs // 10 + zs // 30))
    lines = text.splitlines()
    assert lines[0] == "world=design x=0..299 z=0..299 y=40..78 band=4 step=3"
    assert max(len(line) for line in lines) <= 128 + 8
    assert len(_rows(text, 100)) == 100 + 1 and all(len(row) == 100 for row in _rows(text, 100)[:100])
    assert lines[1].strip().startswith("0") and "288" in lines[1] and lines[2 + 96].startswith("288 ")
    narrow = ascii_heightmap(_heightmap(bounds, xs), max_width=40, legend=False).splitlines()[1:]
    assert len(narrow) == 1 + 38 and max(len(line) for line in narrow) <= 48


def test_marker_lands_on_its_cell_and_in_the_legend() -> None:
    bounds = Bounds2D((-8, -8), (7, 7))
    marker = Marker("home", 3, -5, 70)
    text = ascii_heightmap(_heightmap(bounds, np.full((16, 16), 64)), [marker, Marker("box", 7, 7, 60, "corner")])
    rows = _rows(text, 16)[:16]
    assert rows[3][11] == "A" and "".join(rows).count("A") == 1 and rows[15][15] == "+"
    assert "A home (3,70,-5)" in text.splitlines() and "+ box (7,7)..(7,7)" in text.splitlines()
    assert ascii_heightmap(_heightmap(bounds, np.full((16, 16), 64)), [Marker("far", 40, 40, 1)]).count("A") == 0


def test_water_glyph_only_where_the_top_block_is_liquid() -> None:
    bounds = Bounds2D((0, 0), (3, 3))
    top = np.ones((4, 4), dtype=np.int16)
    top[2, 1] = 2
    text = ascii_heightmap(_heightmap(bounds, np.full((4, 4), 64), top), legend=False)
    rows = _rows(text, 4)
    assert rows[2][1] == "~" and text.count("~") == 1
    assert "~" not in ascii_heightmap(_heightmap(bounds, np.full((4, 4), 64)), legend=False)


def test_band_and_header_follow_the_height_range_unless_given() -> None:
    bounds = Bounds2D((0, 0), (19, 0))
    heights = np.arange(60, 80).reshape(1, 20)
    heights[0, 5] = -1
    text = ascii_heightmap(_heightmap(bounds, heights))
    assert text.splitlines()[0] == "world=design x=0..19 z=0..0 y=60..79 band=2 step=1"
    assert _rows(text, 20)[0] == "..,,: --==++**##%%@@"
    assert text.splitlines()[-1] == "ramp . y<62 to @ y>=78, ~ liquid, space empty"
    assert "band=5 step=1" in ascii_heightmap(_heightmap(bounds, heights), band=5)
    assert _rows(ascii_heightmap(_heightmap(bounds, heights), band=5), 20)[0] == "..... ,,,,:::::-----"
    assert "y=empty" in ascii_heightmap(_heightmap(bounds, np.full((1, 20), -1)))


def test_summary_counts_water_and_flat_columns() -> None:
    heights = np.array([[64, 64, 66, -1]])
    top = np.array([[1, 2, 1, 0]])
    stats = summary(_heightmap(Bounds2D((0, 0), (3, 0)), heights, top))
    assert stats == {"size": (4, 1), "columns": 3, "min": 64, "max": 66, "mean": 194 / 3, "water": 1 / 3, "flat": 2 / 3}
    assert summary(Heightmap(WORLD, Bounds2D((0, 0), (0, 0)), np.full((1, 1), 64, dtype=np.int16)))["water"] is None
    assert summary(Heightmap(WORLD, Bounds2D((0, 0), (0, 0)), np.full((1, 1), -1, dtype=np.int16)))["min"] is None


def test_markers_from_index_and_report_path() -> None:
    index = WorldIndex(
        worlds=[WorldEntry(WORLD, "normal", 0, "design"), WorldEntry("farm", "normal", 0, "farm")],
        locations=[Location("spawn", WORLD, (0, 64, 0)), Location("far", WORLD, (99, 64, 0)), Location("barn", "farm", (0, 64, 0))],
        regions=[NamedRegion("yard", WORLD, (-4, 60, -4), (20, 70, 20))],
    )
    markers = markers_from_index(index, WORLD, Bounds2D((-8, -8), (7, 7)))
    assert markers == [Marker("spawn", 0, 0, 64), Marker("yard", -4, -4, 60, "corner")]
    path = report_path("heightmap", WORLD, Bounds2D((-8, -8), (7, 7)), "txt", datetime(2026, 9, 7, 13, 5, 9))
    assert path == REPORTS_DIR / "heightmap-design--8_-8-16x16-20260907-130509.txt" and REPORTS_DIR.is_dir()
    assert len(RAMP) == 10
