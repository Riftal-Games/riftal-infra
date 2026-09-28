import os
import shutil
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from designer import config, world_index
from designer.blocks import AIR
from designer.bridge import Bridge
from designer.builders import BUILDERS, HeightmapFetch, Palette
from designer.builders.mine_spec import MineSpec
from designer.edits import EditList
from designer.region import Bounds, Region
from tests.fake_bridge import FakeBridge, FakeWorld

MINE_SPEC = {
    "name": "box", "world": "design", "origin": [0, 0, 0], "size": [20, 10, 20], "wall_thickness": 2, "floor_y": 2,
    "entrance": {"side": "north", "width": 3, "height": 3}, "exit_path": {"length": 5, "width": 3},
    "ores": {"stone": 60, "coal_ore": 30, "iron_ore": 10}, "seed": 1, "lights_every": 4, "reset_percent": 60,
}

# Small enough that its blocks are just air and stone, no lights placed (lights_every
# outruns exit_path.length), so it builds clean on the fake bridge's tiny palette too.
SMALL_MINE_SPEC = {
    "name": "tbox", "world": "design", "origin": [0, 0, 0], "size": [7, 6, 7], "wall_thickness": 1, "floor_y": 1,
    "entrance": {"side": "north", "width": 3, "height": 2}, "exit_path": {"length": 2, "width": 3},
    "ores": {"minecraft:stone": 1.0}, "seed": 1, "lights_every": 4, "reset_percent": 60,
}
SMALL_MINE_NAMES = {"tbox", "tbox_interior", "tbox_entrance", "tbox_exit_platform", "tbox_exit", "tbox_spawn", "sell_npc_tbox", "rankup_npc_tbox"}

# Flat inside FakeWorld's default extent (surface 63 everywhere), so the profile is level and no stairs are placed.
SMALL_ROAD_SPEC = {"name": "test_road", "world": "design", "start": [0, 0], "end": [5, 0], "width": 1, "clear_height": 2}

# Deliberately carries no "name": StairsSpec has none by design (DECISIONS.md, 2026-09-28).
SMALL_STAIRS_SPEC = {"world": "design", "from": [0, 64, 0], "direction": "east", "rise": 2, "width": 1}
STONE_PALETTES = {
    "colors": {},
    "palettes": {"test_stone": dict.fromkeys(("wall", "wall_trim", "floor", "ceiling", "light", "sign", "road", "road_edge", "stairs"), "minecraft:stone")},
}
# Each is a kind and a change to SMALL_MINE_SPEC that the index refuses once the `refusable` fixture is up.
REFUSED_BUILDS = [
    pytest.param("mine", {"name": "TBox"}, "must match ^[a-z0-9_]+$", id="bad-name"),
    pytest.param("mine", {"world": "quarry"}, "no such world 'quarry'", id="unlisted-world"),
    pytest.param("twice", {}, "is given twice in one build", id="in-build-duplicate"),
]

# Read at import, before any fixture redirects a path, so the session check watches the working tree itself.
TREE = config.PROJECT_ROOT
COMMITTED_INDEX = world_index.DEFAULT_PATH
# Interpreter and tool caches change under any run, and stack/ is a live server's bind mount; no toolkit writer targets them.
UNWATCHED = {"__pycache__", "stack"}
BEFORE = pytest.StashKey[dict[Path, tuple[int, int]]]()
TOUCHED = pytest.StashKey[list[Path]]()


def _tree_state() -> dict[Path, tuple[int, int]]:
    found = {}
    for top, dirs, files in os.walk(TREE):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in UNWATCHED]
        # A directory counts by existence alone: its mtime moves whenever a pruned cache appears inside it.
        found[Path(top)] = (0, 0)
        for name in files:
            stat = Path(top, name).stat()
            found[Path(top, name)] = (stat.st_mtime_ns, stat.st_size)
    return found


def pytest_sessionstart(session: pytest.Session) -> None:
    session.config.stash[BEFORE] = _tree_state()


def pytest_sessionfinish(session: pytest.Session) -> None:
    """Fails an otherwise green run when any file under the designer tree appeared, changed or vanished."""
    before, after = session.config.stash[BEFORE], _tree_state()
    touched = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    session.config.stash[TOUCHED] = touched
    if touched and session.exitstatus == pytest.ExitCode.OK:
        session.exitstatus = pytest.ExitCode.TESTS_FAILED


def pytest_terminal_summary(terminalreporter: pytest.TerminalReporter) -> None:
    touched = terminalreporter.config.stash.get(TOUCHED, [])
    if touched:
        terminalreporter.section("tests wrote into the working tree", sep="=", red=True, bold=True)
        for path in touched:
            terminalreporter.write_line(str(path), red=True)


@pytest.fixture(autouse=True)
def _runtime_output_in_tmp(tmp_path: Path, tmp_path_factory: pytest.TempPathFactory, monkeypatch: pytest.MonkeyPatch) -> None:
    """Points every snapshot, report and default index writer outside the tree; render and checks bind ``REPORTS_DIR`` at import.

    The index is a per-test copy of the committed file, so a default load reads the same bytes and a default save lands
    in the copy. It sits outside ``tmp_path`` because tests assert on what their own ``tmp_path`` holds.
    """
    monkeypatch.setattr(config, "SNAPSHOTS_DIR", tmp_path / "snapshots")
    monkeypatch.setattr(config, "REPORTS_DIR", tmp_path / "reports")
    monkeypatch.setattr("designer.render.REPORTS_DIR", tmp_path / "reports")
    monkeypatch.setattr("designer.checks.REPORTS_DIR", tmp_path / "reports")
    index_copy = tmp_path_factory.mktemp("index") / COMMITTED_INDEX.name
    shutil.copyfile(COMMITTED_INDEX, index_copy)
    monkeypatch.setattr(world_index, "DEFAULT_PATH", index_copy)


@pytest.fixture
def fake():
    server = FakeBridge()
    server.start()
    yield server
    server.stop()


@pytest.fixture
def refusable(fake: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> FakeBridge:
    """The bridge serves ``quarry``, which no test index lists, and ``twice`` is a mine that emits its first location twice."""
    build_mine = BUILDERS["mine"]

    def twice(spec: dict[str, Any], palette: Palette, fetch: HeightmapFetch) -> EditList:
        edits = build_mine(spec, palette, fetch)
        edits.extras["locations"].append(edits.extras["locations"][0])
        return edits

    monkeypatch.setitem(BUILDERS, "twice", twice)
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    fake.worlds["quarry"] = FakeWorld()
    return fake


@pytest.fixture
def bridge(fake: FakeBridge):
    with Bridge("127.0.0.1", fake.port, fake.token, timeout=2.0, max_retries=1) as client:
        yield client


@pytest.fixture
def flat_plane_with_hole() -> Region:
    """40x8x40: stone floor at y=3 under air, a 2x2 hole at the centre, 3x3 lava in the low corner."""
    region = Region.empty("plane", Bounds((0, 0, 0), (39, 7, 39)))
    region.fill(Bounds((0, 3, 0), (39, 3, 39)), "minecraft:stone")
    region.fill(Bounds((19, 3, 19), (20, 3, 20)), AIR)
    region.fill(Bounds((0, 3, 0), (2, 3, 2)), "minecraft:lava")
    return region


@pytest.fixture
def ramp_region() -> Region:
    """30x12x10: floor at y = x // 3 up to x=23, then two blocks higher from x=24 on."""
    region = Region.empty("ramp", Bounds((0, 0, 0), (29, 11, 9)))
    for x in range(30):
        region.fill(Bounds((x, 0, 0), (x, x // 3 if x < 24 else 9, 9)), "minecraft:stone")
    return region


@pytest.fixture
def ramp_with_ceiling(ramp_region: Region) -> Region:
    """The ramp with a solid layer over two blocks of air above its rising floor, so no step up has head room."""
    for x in range(24):
        ramp_region.fill(Bounds((x, x // 3 + 3, 0), (x, x // 3 + 3, 9)), "minecraft:stone")
    return ramp_region


@pytest.fixture
def box_mine_region() -> tuple[Region, MineSpec]:
    """20x10x20 stone box, two-thick walls, interior 60/30/10 stone, coal, iron from seed 1, a 3x3 north opening onto a 3x5 platform, with the padding ring."""
    spec = MineSpec.from_dict(MINE_SPEC)
    geo = spec.geometry()
    region = Region.empty(spec.world, geo.padding.union(geo.exit_platform))
    region.fill(geo.outer, "minecraft:stone")
    lut = np.array([region.index_of(name) for name in spec.ores], dtype=np.int16)
    weights = np.array(list(spec.ores.values())) / sum(spec.ores.values())
    inner = region.sub(geo.interior)
    inner.blocks[...] = lut[np.random.default_rng(spec.seed).choice(len(lut), size=inner.blocks.shape, p=weights)]
    region.fill(geo.entrance, AIR)
    region.fill(geo.exit_platform, "minecraft:stone")
    return region, spec


@pytest.fixture
def leaky_mine_region(box_mine_region: tuple[Region, MineSpec]) -> tuple[Region, MineSpec]:
    """The box mine with a one-block hole through the east wall at y=3, z=10."""
    region, spec = box_mine_region
    region.fill(Bounds((18, 3, 10), (19, 3, 10)), AIR)
    return region, spec
