"""The pit recipe's two fills: bedrock under the build box, and stone over the mines of layers 4 to 14 (spec 026, criteria 4 and 8)."""

from __future__ import annotations

import gzip
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from designer import fills, level, mcstructure, pit_census
from designer.bridge import Bridge
from designer.config import PROJECT_ROOT
from designer.fills import FillError
from designer.level import LevelError, Saved, build_level, content_sha256, load_recipe, prepare_structures
from designer.pit_index import encode_set, set_name
from designer.region import Bounds, Region, fetch_region
from designer.world_index import Location, WorldEntry, WorldIndex
from tests.fake_bridge import FakeBridge, FakeWorld
from tests.test_structure import MUD, STONE as STONE_I, structure_bytes

BEDROCK, STONE, MUD_NAME = "minecraft:bedrock", "minecraft:stone", "minecraft:packed_mud"
BOX = Bounds((0, 60, 0), (31, 70, 31))
LAYER_1, LAYER_2, LAYER_3 = [(7, 65, 7)], [(5, 65, 5), (6, 65, 6)], [(12, 65, 12)]


@pytest.fixture(autouse=True)
def small_chunks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mcstructure, "BULK_MIN", 4)
    monkeypatch.setattr(mcstructure, "CHUNK_CELLS", 7)


def _read(name: str) -> Any:
    return json.loads((PROJECT_ROOT / name).read_text(encoding="utf-8"))


def test_the_committed_bedrock_floor_is_the_layer_under_the_build_box_across_its_whole_width() -> None:
    recipe, spec = load_recipe("pit"), _read("specs/pit_bedrock.json")
    assert [s.build for s in recipe.steps] == ["structure", "fill_box", "fill_sets"]
    floor = Bounds.from_json(spec["bounds"])
    assert spec["world"] == "pit" and spec["block"] == BEDROCK
    assert floor == Bounds((-184, -64, -184), (184, -64, 184))
    assert floor.min[1] == recipe.bounds.min[1] - 1
    assert (floor.min[0], floor.min[2], floor.max[0], floor.max[2]) == (recipe.bounds.min[0], recipe.bounds.min[2], recipe.bounds.max[0], recipe.bounds.max[2])


def test_the_committed_bedrock_fill_holds_every_position_at_y_minus_64_and_nothing_above(fake: FakeBridge, bridge: Bridge) -> None:
    fake.worlds["pit"] = FakeWorld()
    edits = fills.box_edits(_read("specs/pit_bedrock.json"))
    assert edits.apply(bridge).ok
    floor = fetch_region(bridge, "pit", Bounds((-184, -64, -184), (184, -64, 184)))
    assert floor.blocks.shape == (1, 369, 369)
    assert {floor.palette[i] for i in np.unique(floor.blocks)} == {BEDROCK}
    above = fetch_region(bridge, "pit", Bounds((-184, -63, -184), (184, -63, 184)))
    assert BEDROCK not in {above.palette[i] for i in np.unique(above.blocks)}


def test_the_committed_stone_fill_names_layers_4_to_14_and_each_has_a_set_the_manifest_vouches_for() -> None:
    spec = _read("specs/pit_stone.json")
    assert (spec["layers"], spec["from"], spec["block"]) == (list(range(4, 15)), MUD_NAME, STONE)
    sets = fills.read_sets(PROJECT_ROOT / spec["sets"], spec["manifest"], spec["layers"])
    assert sorted(sets) == spec["layers"]
    recipe = load_recipe("pit")
    assert all(recipe.bounds.intersect(box) == box and len(points) > 0 for box, points in sets.values())


def _write_sets(root: Path, sets: dict[int, tuple[tuple[int, int, int], tuple[int, int, int], list[tuple[int, int, int]]]]) -> None:
    (root / "pit" / "mine_sets").mkdir(parents=True, exist_ok=True)
    lines = []
    for layer, (origin, size, points) in sets.items():
        data = encode_set(origin, size, np.array(points))
        (root / "pit" / set_name(layer)).write_bytes(data)
        lines.append(f"{hashlib.sha256(data).hexdigest()}  {set_name(layer)}\n")
    (root / "pit" / "pit.sha256").write_text("".join(lines), encoding="utf-8", newline="\n")


SETS = {
    1: ((7, 65, 7), (1, 1, 1), LAYER_1),
    2: ((5, 65, 5), (2, 1, 2), LAYER_2),
    3: ((11, 65, 11), (3, 1, 3), LAYER_3),
}
STONE_SPEC = {"world": "zt", "sets": "pit", "manifest": "pit.sha256", "layers": [2, 3], "from": MUD_NAME, "block": STONE}


def _region(mud: list[tuple[int, int, int]]) -> Region:
    region = Region.empty("zt", BOX)
    for pos in mud:
        region.set(*pos, MUD_NAME)
    return region


def test_a_stone_fill_replaces_the_placeholder_only_in_the_layers_it_names(tmp_path: Path) -> None:
    _write_sets(tmp_path, SETS)
    region = _region([*LAYER_1, *LAYER_2, *LAYER_3])
    edits = fills.set_edits(STONE_SPEC, tmp_path, region)
    for op in edits.ops:
        op.paint(region)
    assert [region.get(*p) for p in LAYER_2 + LAYER_3] == [STONE] * 3
    assert region.get(*LAYER_1[0]) == MUD_NAME


def test_a_set_position_that_is_not_the_placeholder_is_refused_naming_it(tmp_path: Path) -> None:
    _write_sets(tmp_path, SETS)
    with pytest.raises(FillError, match=r"layer 2: 1 set positions do not hold minecraft:packed_mud, first at \(6, 65, 6\)"):
        fills.set_edits(STONE_SPEC, tmp_path, _region([*LAYER_1, LAYER_2[0], *LAYER_3]))


def test_a_placeholder_in_a_set_box_that_the_set_lacks_is_refused(tmp_path: Path) -> None:
    _write_sets(tmp_path, SETS)
    with pytest.raises(FillError, match="layer 3: its box holds 2 minecraft:packed_mud, its set has 1 positions"):
        fills.set_edits(STONE_SPEC, tmp_path, _region([*LAYER_2, *LAYER_3, (13, 65, 13)]))


def test_a_set_the_manifest_does_not_vouch_for_is_refused(tmp_path: Path) -> None:
    _write_sets(tmp_path, SETS)
    path = tmp_path / "pit" / set_name(2)
    path.write_bytes(path.read_bytes() + b"\x00")
    with pytest.raises(FillError, match="layer_02.bin differs from the sha256 pit.sha256 names"):
        fills.set_edits(STONE_SPEC, tmp_path, _region([*LAYER_2, *LAYER_3]))



def test_a_set_box_outside_the_level_read_is_refused(tmp_path: Path) -> None:
    _write_sets(tmp_path, {2: SETS[2], 3: ((40, 65, 40), (1, 1, 1), [(40, 65, 40)])})
    with pytest.raises(FillError, match="layer 3's set box"):
        fills.set_edits(STONE_SPEC, tmp_path, _region(LAYER_2))



RECIPE = {
    "generator": "normal", "seed": 7, "bounds": BOX.to_json(),
    "steps": [
        {"build": "structure", "spec": "specs/zt.json"},
        {"build": "fill_box", "spec": "specs/zt_bedrock.json"},
        {"build": "fill_sets", "spec": "specs/zt_stone.json"},
    ],
}
STRUCTURE_SPEC = {"world": "zt", "source": "src", "file": "s.mcstructure.gz", "origin": [0, 64, 0], "min_corner": [0, 0, 0], "substitutes": {}}
BEDROCK_SPEC = {"world": "zt", "bounds": {"min": [0, 59, 0], "max": [31, 59, 31]}, "block": BEDROCK}


@pytest.fixture
def level_root(tmp_path: Path, fake: FakeBridge) -> Path:
    placed = {(x - 0, y - 64, z - 0): MUD for x, y, z in (*LAYER_1, *LAYER_2, *LAYER_3)}
    placed[(0, 0, 0)] = STONE_I
    raw = structure_bytes((20, 3, 20), placed, {})
    for folder in ("levels", "specs", "src"):
        (tmp_path / folder).mkdir()
    (tmp_path / "src" / "s.mcstructure.gz").write_bytes(gzip.compress(raw, mtime=0))
    pit_census.write_json(tmp_path / "src" / "pins.json", {"files": {}, "structure_sha256": hashlib.sha256(raw).hexdigest()})
    for name, data in (("levels/zt.json", RECIPE), ("specs/zt.json", STRUCTURE_SPEC), ("specs/zt_bedrock.json", BEDROCK_SPEC), ("specs/zt_stone.json", STONE_SPEC)):
        (tmp_path / name).write_text(json.dumps(data), encoding="utf-8")
    (tmp_path / "checks.yaml").write_text("version: 1\nchecks:\n  - check: offdisk_clear\n    zone: zt\n    world: zt\n", encoding="utf-8")
    (tmp_path / "mines.yml").write_text("worlds:\n  mine_x: worlds/mine_x.json\n", encoding="utf-8")
    _write_sets(tmp_path, SETS)
    fake.worlds["zt"] = FakeWorld()
    return tmp_path


def _build(bridge: Bridge, fake: FakeBridge, root: Path) -> Path:
    converted = prepare_structures(load_recipe("zt", root), root, root / "out")
    fake.structure_dir = root / "out"
    index = WorldIndex(default_world="zt", worlds=[WorldEntry("zt", "normal", 7, "pit")], locations=[Location("zt_spawn", "zt", (40, 64, 40))])
    return build_level(
        bridge, "zt", lambda: Saved("sha256:image", "bridge-commit", "toolkit-commit", 4096), root=root, index=index,
        checks_path=root / "checks.yaml", mines_config=root / "mines.yml", converted=converted,
    )


def test_a_build_writes_bedrock_then_reads_the_level_for_its_checks_then_writes_stone(
    fake: FakeBridge, bridge: Bridge, level_root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    seen: list[list[str]] = []
    run_checks = level._run_checks

    def spy(bridge: Bridge, recipe: Any, index: Any, specs: Any, region: Region) -> Any:
        seen.append([region.get(*p) for p in LAYER_2 + LAYER_3])
        return run_checks(bridge, recipe, index, specs, region)

    monkeypatch.setattr(level, "_run_checks", spy)
    lock = json.loads(_build(bridge, fake, level_root).read_text(encoding="utf-8"))
    assert seen == [[MUD_NAME] * 3]
    ops = [r["op"] for r in fake.requests]
    assert ops.index("load_structure") < ops.index("fill") < ops.index("get_region") < ops.index("replace") < ops.index("scan_items")
    boxes = [Bounds((5, 65, 5), (6, 65, 6)).to_json(), Bounds((11, 65, 11), (13, 65, 13)).to_json()]
    assert [r["args"]["bounds"] for r in fake.requests if r["op"] == "replace"] == boxes
    floor = fetch_region(bridge, "zt", Bounds((0, 59, 0), (31, 59, 31)))
    assert {floor.palette[i] for i in np.unique(floor.blocks)} == {BEDROCK}
    region = fetch_region(bridge, "zt", BOX)
    assert [region.get(*p) for p in LAYER_2 + LAYER_3] == [STONE] * 3
    assert region.get(*LAYER_1[0]) == MUD_NAME
    assert lock["content_sha256"] == content_sha256(region)
    assert lock["inputs"]["pit/pit.sha256"] == hashlib.sha256((level_root / "pit" / "pit.sha256").read_bytes()).hexdigest()
    assert {"specs/zt_bedrock.json", "specs/zt_stone.json"} <= set(lock["inputs"])


def test_a_build_whose_set_is_not_vouched_for_writes_no_stone_and_no_lock(fake: FakeBridge, bridge: Bridge, level_root: Path) -> None:
    path = level_root / "pit" / set_name(3)
    path.write_bytes(path.read_bytes() + b"\x00")
    with pytest.raises(LevelError, match="layer_03.bin differs"):
        _build(bridge, fake, level_root)
    assert "replace" not in [r["op"] for r in fake.requests]
    assert not (level_root / "levels" / "zt.lock.json").exists()
