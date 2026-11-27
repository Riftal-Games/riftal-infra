"""The ``structure`` builder: cells on the world grid, the substitutes, hard rule 1, batching and the recipe's lock."""

from __future__ import annotations

import gzip
import hashlib
import json
import struct
from pathlib import Path
from typing import Any

import pytest

from designer import mcstructure, pit_census
from designer.bridge import Bridge
from designer.level import (
    LevelError, Saved, build_level, check_index, content_sha256, load_recipe, pregen_bounds, prepare_structures,
)
from designer.region import Bounds, fetch_region
from designer.structure import CELL, StructureBuildError, StructureSpec, batches, convert
from designer.world_index import Location, WorldEntry, WorldIndex
from tests.fake_bridge import FakeBridge, FakeWorld

DRIPSTONE, SCAFFOLDING = "minecraft:dripstone_block", "minecraft:scaffolding[stability=0,stability_check=true]"
BED = "minecraft:bed[direction=0,head_piece_bit=true,occupied_bit=false]"
PALETTE = [
    "minecraft:air", "minecraft:stone", "minecraft:chest[facing_direction=2]", "minecraft:campfire[direction=0,extinguished=false]",
    BED, DRIPSTONE, SCAFFOLDING, "minecraft:moss_block", "minecraft:packed_mud",
]
AIR, STONE, CHEST, CAMPFIRE, BED_I, DRIP, SCAFF, MOSS, MUD = range(9)
SUBSTITUTES = {
    "minecraft:dripstone_block": "minecraft:brown_terracotta",
    "minecraft:moss_block": "minecraft:green_terracotta",
    "minecraft:scaffolding": "minecraft:bamboo_planks",
}


def _s(text: str) -> bytes:
    raw = text.encode()
    return struct.pack("<H", len(raw)) + raw


def _tag(kind: int, name: str, payload: bytes) -> bytes:
    return bytes([kind]) + _s(name) + payload


def _compound(*items: bytes) -> bytes:
    return b"".join(items) + b"\x00"


def _list(kind: int, payloads: list[bytes]) -> bytes:
    return bytes([kind]) + struct.pack("<i", len(payloads)) + b"".join(payloads)


def _ints(values: list[int]) -> bytes:
    return _list(3, [struct.pack("<i", v) for v in values])


def _entity(kind: str, **fields: bytes) -> bytes:
    return _compound(_tag(8, "id", _s(kind)), *(_tag(k[0], k[1], v) for k, v in fields.items()))  # type: ignore[index]


def structure_bytes(size: tuple[int, int, int], placed: dict[tuple[int, int, int], int], entities: dict[tuple[int, int, int], bytes], layer1: int = -1) -> bytes:
    """A ``.mcstructure`` whose cell ``(x, y, z)`` holds ``placed.get(.., -1)``, with block entity data from ``entities``."""
    sx, sy, sz = size
    cells = [placed.get((x, y, z), -1) for x in range(sx) for y in range(sy) for z in range(sz)]
    second = [layer1] + [-1] * (len(cells) - 1)
    palette = _list(10, [
        _compound(_tag(8, "name", _s(key.partition("[")[0])), _tag(10, "states", _compound()), _tag(3, "version", struct.pack("<i", 1)))
        for key in PALETTE
    ])
    data = _compound(*(
        _tag(10, str((x * sy + y) * sz + z), _compound(_tag(10, "block_entity_data", body))) for (x, y, z), body in entities.items()
    ))
    structure = _compound(
        _tag(9, "block_indices", _list(9, [_ints(cells), _ints(second)])),
        _tag(9, "entities", _list(10, [])),
        _tag(10, "palette", _compound(_tag(10, "default", _compound(_tag(9, "block_palette", palette), _tag(10, "block_position_data", data))))),
    )
    return _tag(10, "", _compound(_tag(9, "size", _ints(list(size))), _tag(10, "structure", structure)))


def bed_entity(colour: int) -> bytes:
    return _compound(_tag(8, "id", _s("Bed")), _tag(1, "color", bytes([colour])))


def chest_entity() -> bytes:
    item = _compound(_tag(8, "Name", _s("minecraft:diamond")), _tag(1, "Count", bytes([64])))
    return _compound(_tag(8, "id", _s("Chest")), _tag(9, "Items", _list(10, [item])))


def campfire_entity() -> bytes:
    item = _compound(_tag(8, "Name", _s("minecraft:diamond")), _tag(1, "Count", bytes([1])))
    return _compound(_tag(8, "id", _s("Campfire")), *(_tag(10, f"Item{n}", item) for n in range(1, 5)))


SIZE = (5, 4, 6)
# Structure minimum at world (-3, -59, -2): none of the three axes is 16-aligned.
SPEC = StructureSpec("zt", "src", "s.mcstructure.gz", (0, 66, 0), (-3, -125, -2), SUBSTITUTES)
LOW = (-3, -59, -2)
PLACED = {
    (0, 0, 0): STONE, (4, 0, 0): STONE, (0, 0, 5): DRIP, (4, 3, 5): SCAFF, (2, 1, 2): CHEST, (3, 1, 3): CAMPFIRE,
    (1, 2, 1): BED_I, (2, 2, 4): MOSS, (1, 0, 1): AIR,
}
ENTITIES = {(2, 1, 2): chest_entity(), (3, 1, 3): campfire_entity(), (1, 2, 1): bed_entity(14)}


@pytest.fixture(autouse=True)
def small_chunks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mcstructure, "BULK_MIN", 4)
    monkeypatch.setattr(mcstructure, "CHUNK_CELLS", 7)


def _source(tmp_path: Path, raw: bytes) -> Path:
    path = tmp_path / "s.mcstructure.gz"
    path.write_bytes(gzip.compress(raw, mtime=0))
    return path


def _convert(tmp_path: Path, raw: bytes | None = None, spec: StructureSpec = SPEC) -> tuple[Path, Any]:
    out = tmp_path / "cells"
    out.mkdir()
    return out, convert(_source(tmp_path, raw or structure_bytes(SIZE, PLACED, ENTITIES)), out, spec)


def _docs(out: Path, converted: Any) -> dict[tuple[int, int, int], dict[str, Any]]:
    return {tuple(c["at"]): json.loads((out / c["file"]).read_text()) for c in converted.cells}


def _name_at(docs: dict[tuple[int, int, int], dict[str, Any]], x: int, y: int, z: int) -> str | None:
    at = (x - x % CELL, y - y % CELL, z - z % CELL)
    if at not in docs:
        return None
    doc = docs[at]
    return doc["palette"][doc["blocks"][((y % CELL) * CELL + z % CELL) * CELL + x % CELL]]


def test_cells_are_cut_on_the_world_grid_not_the_structure_grid(tmp_path: Path) -> None:
    out, converted = _convert(tmp_path)
    docs = _docs(out, converted)
    assert set(docs) == {(-16, -64, -16), (-16, -64, 0), (0, -64, -16), (0, -64, 0)}
    assert all(v % CELL == 0 for at in docs for v in at)
    assert all(len(doc["blocks"]) == 4096 for doc in docs.values())
    for (x, y, z), index in PLACED.items():
        want = PALETTE[index].partition("[")[0] if index != AIR else "minecraft:air"
        want = SUBSTITUTES.get(want, want)
        assert _name_at(docs, LOW[0] + x, LOW[1] + y, LOW[2] + z) == want, (x, y, z)


def test_a_position_outside_the_structure_is_air_and_a_cell_of_air_is_not_written(tmp_path: Path) -> None:
    out, converted = _convert(tmp_path)
    docs = _docs(out, converted)
    assert _name_at(docs, -16, -64, -16) == "minecraft:air"
    only_air = {(0, 0, 0): AIR, (1, 1, 1): AIR}
    out2 = tmp_path / "again"
    out2.mkdir()
    again = convert(_source(tmp_path, structure_bytes((2, 2, 2), only_air, {})), out2, SPEC)
    assert again.cells == []


def test_the_manifest_lists_every_cell_with_its_file_hash(tmp_path: Path) -> None:
    out, converted = _convert(tmp_path)
    listed = json.loads((out / "manifest.json").read_text())["cells"]
    assert listed == converted.cells
    for cell in listed:
        assert hashlib.sha256((out / cell["file"]).read_bytes()).hexdigest() == cell["sha256"]


def test_the_substitutes_replace_every_state_of_a_name_and_are_counted(tmp_path: Path) -> None:
    out, converted = _convert(tmp_path)
    names = {name for doc in _docs(out, converted).values() for name in doc["palette"]}
    assert not {DRIPSTONE, SCAFFOLDING, "minecraft:moss_block"} & names
    assert {"minecraft:brown_terracotta", "minecraft:bamboo_planks", "minecraft:green_terracotta"} <= names
    assert converted.substituted == {"minecraft:dripstone_block": 1, "minecraft:scaffolding": 1, "minecraft:moss_block": 1}
    assert converted.mapping == SUBSTITUTES


def test_an_item_holding_block_entity_leaves_no_item_data_in_any_cell(tmp_path: Path) -> None:
    out, converted = _convert(tmp_path)
    for cell in converted.cells:
        raw = (out / cell["file"]).read_bytes()
        for needle in (b"Item", b"diamond", b"Count", b"Name", b"Chest", b"Campfire"):
            assert needle not in raw, (cell["file"], needle)
    assert converted.dropped_block_entities == {"Chest": 1, "Campfire": 1}


def test_only_a_bed_colour_survives_as_a_block_entity(tmp_path: Path) -> None:
    out, converted = _convert(tmp_path)
    entities = [e for doc in _docs(out, converted).values() for e in doc.get("block_entities", [])]
    assert entities == [{"pos": [LOW[0] + 1 - (-16), LOW[1] + 2 - (-64), LOW[2] + 1 - (-16)], "color": 14}]
    cell = _docs(out, converted)[(-16, -64, -16)]
    x, y, z = cell["block_entities"][0]["pos"]
    assert cell["palette"][cell["blocks"][(y * 16 + z) * 16 + x]] == "minecraft:bed"


def test_a_bed_entity_on_another_block_is_refused(tmp_path: Path) -> None:
    raw = structure_bytes(SIZE, PLACED, {**ENTITIES, (0, 0, 0): bed_entity(1)})
    with pytest.raises(StructureBuildError, match="on minecraft:stone"):
        _convert(tmp_path, raw)


@pytest.mark.parametrize("colour", [-1, 16])
def test_a_bed_colour_out_of_range_is_refused(tmp_path: Path, colour: int) -> None:
    raw = structure_bytes(SIZE, PLACED, {(1, 2, 1): bed_entity(colour & 0xFF)})
    with pytest.raises(StructureBuildError, match="not 0 to 15"):
        _convert(tmp_path, raw)


def test_a_second_layer_block_is_refused_not_dropped(tmp_path: Path) -> None:
    with pytest.raises(StructureBuildError, match="layer 1 holds 1 blocks"):
        _convert(tmp_path, structure_bytes(SIZE, PLACED, ENTITIES, layer1=STONE))


def _grid(cx: range, cy: range, cz: range) -> list[dict[str, Any]]:
    return [{"file": f"{x}_{y}_{z}", "sha256": "0" * 64, "at": [x * 16, y * 16, z * 16]} for x in cx for y in cy for z in cz]


def _edges(group: list[dict[str, Any]]) -> list[int]:
    return [max(c["at"][a] for c in group) + 16 - min(c["at"][a] for c in group) for a in range(3)]


@pytest.mark.parametrize("max_edge", [128, 64, 32, 16])
def test_batches_keep_every_cell_once_and_every_box_within_the_edge(max_edge: int) -> None:
    cells = _grid(range(-12, 12), range(-4, 18), range(-12, 12))
    grouped = batches(cells, max_edge)
    assert sorted(c["file"] for g in grouped for c in g) == sorted(c["file"] for c in cells)
    assert all(max(_edges(g)) <= max_edge for g in grouped)


def test_the_whole_pit_grid_is_sixty_four_batches_of_at_most_512_cells_at_the_default_edge() -> None:
    grouped = batches(_grid(range(-12, 12), range(-4, 18), range(-12, 12)))
    assert len(grouped) == 64
    assert max(len(g) for g in grouped) == 512


def test_a_sparse_spread_is_not_one_batch() -> None:
    far = [{"file": "a", "sha256": "0" * 64, "at": [-192, -64, -192]}, {"file": "b", "sha256": "0" * 64, "at": [176, 272, 176]}]
    assert [len(g) for g in batches(far)] == [1, 1]


RECIPE = {
    "generator": "normal", "seed": 7, "bounds": {"min": [0, 60, 0], "max": [31, 70, 31]},
    "steps": [{"build": "structure", "spec": "specs/zt.json"}],
}
LEVEL_SPEC = {
    "world": "zt", "source": "src", "file": "s.mcstructure.gz", "origin": [0, 64, 0], "min_corner": [0, 0, 0], "substitutes": SUBSTITUTES,
}


@pytest.fixture
def level_root(tmp_path: Path, fake: FakeBridge) -> Path:
    raw = structure_bytes((20, 3, 20), {(0, 0, 0): STONE, (19, 2, 19): DRIP, (5, 1, 5): CHEST, (6, 1, 6): BED_I}, {(5, 1, 5): chest_entity(), (6, 1, 6): bed_entity(3)})
    (tmp_path / "levels").mkdir()
    (tmp_path / "specs").mkdir()
    source = tmp_path / "src"
    source.mkdir()
    (source / "s.mcstructure.gz").write_bytes(gzip.compress(raw, mtime=0))
    pit_census.write_json(source / "pins.json", {"files": {}, "structure_sha256": hashlib.sha256(raw).hexdigest()})
    (tmp_path / "levels" / "zt.json").write_text(json.dumps(RECIPE), encoding="utf-8")
    (tmp_path / "specs" / "zt.json").write_text(json.dumps(LEVEL_SPEC), encoding="utf-8")
    (tmp_path / "checks.yaml").write_text("version: 1\nchecks:\n  - check: offdisk_clear\n    zone: zt\n    world: zt\n", encoding="utf-8")
    (tmp_path / "mines.yml").write_text("worlds:\n  mine_x: worlds/mine_x.json\n", encoding="utf-8")
    fake.worlds["zt"] = FakeWorld()
    return tmp_path


def _index() -> WorldIndex:
    return WorldIndex(default_world="zt", worlds=[WorldEntry("zt", "normal", 7, "pit")], locations=[Location("zt_spawn", "zt", (40, 64, 40))])


def _run(bridge: Bridge, root: Path, converted: Any) -> Path:
    return build_level(
        bridge, "zt", lambda: Saved("sha256:image", "bridge-commit", "toolkit-commit", 4096), root=root, index=_index(),
        checks_path=root / "checks.yaml", mines_config=root / "mines.yml", converted=converted,
    )


def test_a_structure_level_loads_its_cells_in_batches_and_writes_the_lock(fake: FakeBridge, bridge: Bridge, level_root: Path) -> None:
    recipe = load_recipe("zt", level_root)
    converted = prepare_structures(recipe, level_root, level_root / "out")
    fake.structure_dir = level_root / "out"
    lock = json.loads(_run(bridge, level_root, converted).read_text(encoding="utf-8"))
    loads = [r["args"] for r in fake.requests if r["op"] == "load_structure"]
    assert [len(r["cells"]) for r in loads] == [len(g) for g in batches(converted.cells)]
    assert sorted(c["file"] for r in loads for c in r["cells"]) == sorted(c["file"] for c in converted.cells)
    assert all(r["world"] == "zt" for r in loads)
    pregen = [i for i, r in enumerate(fake.requests) if r["op"] == "pregen"]
    assert pregen and max(pregen) < min(i for i, r in enumerate(fake.requests) if r["op"] == "load_structure")
    region = fetch_region(bridge, "zt", Bounds((0, 60, 0), (31, 70, 31)))
    assert lock["content_sha256"] == content_sha256(region)
    assert lock["structure"] == {
        "structure_sha256": converted.structure_sha256, "cells": len(converted.cells), "cells_sha256": converted.cells_sha256,
        "substitutes": SUBSTITUTES, "substituted": {"minecraft:dripstone_block": 1}, "dropped_block_entities": {"Chest": 1},
    }
    assert sorted(lock["inputs"]) == ["levels/zt.json", "specs/zt.json", "src/pins.json"]


def test_a_step_with_no_converted_cells_is_refused(fake: FakeBridge, bridge: Bridge, level_root: Path) -> None:
    with pytest.raises(LevelError, match="no converted cells"):
        _run(bridge, level_root, None)
    assert not (level_root / "levels" / "zt.lock.json").exists()


def test_cells_hashed_wrong_fail_the_load(fake: FakeBridge, bridge: Bridge, level_root: Path) -> None:
    converted = prepare_structures(load_recipe("zt", level_root), level_root, level_root / "out")
    fake.structure_dir = level_root / "out"
    first = level_root / "out" / converted.cells[0]["file"]
    first.write_bytes(first.read_bytes() + b" ")
    with pytest.raises(Exception, match="another sha256"):
        _run(bridge, level_root, converted)
    assert not (level_root / "levels" / "zt.lock.json").exists()


def test_a_source_that_is_not_the_pinned_bytes_is_refused(level_root: Path) -> None:
    pit_census.write_json(level_root / "src" / "pins.json", {"files": {}, "structure_sha256": "0" * 64})
    with pytest.raises(LevelError, match="pins.json records"):
        prepare_structures(load_recipe("zt", level_root), level_root, level_root / "out")


def test_a_directory_holding_other_cells_is_refused(level_root: Path) -> None:
    (level_root / "out").mkdir()
    (level_root / "out" / "stale.json").write_text("{}")
    with pytest.raises(LevelError, match="is not empty"):
        prepare_structures(load_recipe("zt", level_root), level_root, level_root / "out")


def test_a_recipe_without_a_structure_step_converts_nothing(level_root: Path) -> None:
    recipe = load_recipe("zt", level_root)
    assert prepare_structures(type(recipe)(**{**recipe.__dict__, "steps": ()}), level_root, level_root / "out") is None


def test_the_committed_pit_recipe_covers_chunks_minus_12_to_11_and_agrees_with_the_index() -> None:
    recipe = load_recipe("pit")
    check_index(recipe, WorldIndex.load())
    assert (recipe.generator, recipe.bounds) == ("void", Bounds((-184, -63, -184), (184, 282, 184)))
    pre = pregen_bounds(recipe.bounds)
    assert pre.min[0] >> 4 <= -12 and pre.min[1] >> 4 <= -12 and pre.max[0] >> 4 >= 11 and pre.max[1] >> 4 >= 11
    spec = StructureSpec.from_dict(json.loads((pit_census.SOURCE_DIR.parents[1] / recipe.steps[0].spec).read_text()))
    census = json.loads((pit_census.SOURCE_DIR / "census.json").read_text())
    assert spec.origin == (0, 66, 0)
    low = spec.world_min()
    assert [low[a] + census["size"][a] - 1 for a in range(3)] == list(recipe.bounds.max)
    assert list(low) == list(recipe.bounds.min)


def test_every_state_the_core_cannot_read_has_a_substitute_the_core_can() -> None:
    spec = StructureSpec.from_dict(json.loads((pit_census.SOURCE_DIR.parents[1] / "specs" / "pit_structure.json").read_text()))
    census = json.loads((pit_census.SOURCE_DIR / "census.json").read_text())
    names = {s["key"]: s["name"] for s in census["states"]}
    unresolved = {names[row["key"]] for row in census["resolution"]["unresolved"]}
    assert unresolved == set(spec.substitutes)
    assert not set(spec.substitutes.values()) & unresolved
