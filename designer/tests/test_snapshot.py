import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import numpy as np
import pytest

from designer import __version__, config
from designer.blocks import AIR
from designer.bridge import Bridge
from designer.edits import EditList, Fill, SetBlock
from designer.region import Bounds, Bounds2D, Region, fetch_heightmap, fetch_region
from designer.snapshot import Snapshot, UndoStack, diff, load, restore, save, take
from tests.fake_bridge import FakeBridge

WORLD = "design"
STONE, GLASS = "minecraft:stone", "minecraft:glass"
BOX = Bounds((0, 60, 0), (15, 66, 15))


@pytest.fixture(autouse=True)
def snapshots_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(config, "SNAPSHOTS_DIR", tmp_path / "snapshots")
    return tmp_path / "snapshots"


def _writes(fake: FakeBridge) -> list[dict]:
    return [r for r in fake.requests if r["op"] in ("set_blocks", "fill", "replace")]


def test_take_then_load_round_trips_the_region(fake: FakeBridge, bridge: Bridge, snapshots_dir: Path) -> None:
    snap, region = take(bridge, WORLD, BOX, "before_fill"), fetch_region(bridge, WORLD, BOX)
    assert snap.path == snapshots_dir / WORLD / f"{snap.timestamp}-before_fill.npz" and snap.path.is_file()
    assert (snap.world, snap.bounds, snap.label) == (WORLD, BOX, "before_fill")
    for got in (snap.region, load(snap.path).region):
        assert (got.world, got.bounds, got.palette, got.blocks.dtype) == (WORLD, BOX, region.palette, np.int16)
        np.testing.assert_array_equal(got.blocks, region.blocks)
    with np.load(snap.path) as data:
        meta = json.loads(data["meta"].item())
    assert meta == {"world": WORLD, "timestamp": snap.timestamp, "label": "before_fill", "toolkit": __version__, "order": "yzx"}
    with pytest.raises(ValueError, match="label"):
        save(region, "no spaces")
    with pytest.raises(ValueError, match="world"):
        save(Region.empty("no spaces", BOX), "ok")


def test_diff_counts_bbox_and_by_type_after_remapping_palettes() -> None:
    a = Region.empty(WORLD, BOX, STONE)
    b = Region(WORLD, BOX, np.full(BOX.shape, 2, dtype=np.int16), [AIR, GLASS, STONE])
    assert diff(a, b) == diff(a, a) and diff(a, a).changed == 0 and diff(a, a).bbox is None and diff(a, a).by_type == {}
    b.fill(Bounds((2, 61, 3), (9, 61, 3)), GLASS)
    b.set(0, 66, 15, AIR)
    out = diff(a, b)
    assert (out.changed, out.bbox) == (9, Bounds((0, 61, 3), (9, 66, 15)))
    assert out.by_type == {AIR: {"removed": 0, "added": 1}, STONE: {"removed": 9, "added": 0}, GLASS: {"removed": 0, "added": 8}}
    assert a.palette == [AIR, STONE] and diff(b, a).by_type[STONE] == {"removed": 0, "added": 9}
    with pytest.raises(ValueError, match="cannot compare"):
        diff(a, Region.empty(WORLD, Bounds((0, 60, 0), (15, 66, 14))))


def test_restore_only_changed_sends_the_changed_cells_and_the_fake_matches_the_snapshot(fake: FakeBridge, bridge: Bridge) -> None:
    snap = take(bridge, WORLD, BOX, "pre")
    EditList(WORLD, [Fill(Bounds((0, 64, 0), (11, 64, 0)), GLASS), SetBlock(5, 65, 5, STONE), SetBlock(3, 63, 3, AIR)]).apply(bridge)
    assert diff(snap, fetch_region(bridge, WORLD, BOX)).changed == 14
    fake.requests.clear()
    assert restore(bridge, snap, dry_run=True).blocks == 0 and _writes(fake) == []
    result = restore(bridge, snap)
    assert (result.ok, result.blocks, [r["op"] for r in _writes(fake)]) == (True, 14, ["set_blocks", "fill", "set_blocks"])
    assert [r["args"]["blocks"] for r in _writes(fake) if r["op"] == "set_blocks"] == [[[3, 63, 3, "minecraft:grass_block"]], [[5, 65, 5, AIR]]]
    assert [r["args"]["bounds"] for r in _writes(fake) if r["op"] == "fill"] == [Bounds((0, 64, 0), (11, 64, 0)).to_json()]
    assert diff(snap, fetch_region(bridge, WORLD, BOX)).changed == 0
    assert isinstance(result.before_result, Snapshot) and result.before_result.label == "restore" and result.before_result.path.is_file()
    assert result.before_result.bounds == Bounds((0, 63, 0), (11, 65, 5))
    assert diff(result.before_result, snap.region.sub(result.before_result.bounds)).changed == 14


def test_undo_manifest_survives_a_new_stack_and_undo_restores_the_fake(fake: FakeBridge, bridge: Bridge, snapshots_dir: Path) -> None:
    snap = take(bridge, WORLD, BOX, "fill")
    entry_id = UndoStack(session="s1").push(snap, "fill")
    EditList(WORLD, [Fill(Bounds((0, 64, 0), (7, 64, 7)), GLASS)]).apply(bridge)
    assert fetch_heightmap(bridge, WORLD, Bounds2D((0, 0), (8, 8)), need_top=True).top_name(7, 7) == GLASS
    fresh = UndoStack(session="s2")
    assert (entry_id, fresh.manifest) == (1, snapshots_dir / "undo-manifest.json")
    assert [(e["id"], e["session"], e["op"], e["restored"], e["path"]) for e in fresh.entries()] == [(1, "s1", "fill", False, str(snap.path))]
    assert fresh.entries(session="s2") == [] and diff(snap, fetch_region(bridge, WORLD, BOX)).changed == 64
    assert [r.blocks for r in fresh.undo(bridge, dry_run=True)] == [0] and fresh.entries()[0]["restored"] is False
    results = fresh.undo(bridge)
    assert [(r.ok, r.blocks) for r in results] == [(True, 64)] and diff(snap, fetch_region(bridge, WORLD, BOX)).changed == 0
    undone = results[0].before_result
    assert [(e["id"], e["session"], e["op"], e["restored"], e["path"]) for e in UndoStack().entries()] == [
        (1, "s1", "fill", True, str(snap.path)), (2, "s2", "undo", False, str(undone.path)),
    ]
    assert fresh.undo(bridge) == [] and diff(snap, fetch_region(bridge, WORLD, BOX)).changed == 0
    assert [(r.ok, r.blocks) for r in fresh.undo(bridge, include_undo=True)] == [(True, 64)]
    assert diff(undone, fetch_region(bridge, WORLD, undone.bounds)).changed == 0
    assert [(e["id"], e["op"], e["restored"]) for e in fresh.entries()] == [(1, "fill", True), (2, "undo", True), (3, "undo", False)]
    assert sorted(p.name for p in snapshots_dir.iterdir()) == [WORLD, "undo-manifest.json"]


def test_restore_of_an_unchanged_region_sends_nothing_and_only_changed_off_sends_every_cell(fake: FakeBridge, bridge: Bridge) -> None:
    snap = take(bridge, WORLD, BOX, "pre")
    fake.requests.clear()
    result = restore(bridge, snap)
    assert (result.ok, result.blocks, result.before_result, _writes(fake)) == (True, 0, None, [])
    fake.requests.clear()
    result = restore(bridge, snap, only_changed=False)
    assert (result.ok, result.blocks, result.before_result.bounds) == (True, int(np.prod(BOX.shape)), BOX)
    assert [r["op"] for r in fake.requests].count("get_region") == 1 and _writes(fake) != []
    assert diff(snap, fetch_region(bridge, WORLD, BOX)).changed == 0


def test_a_failed_manifest_write_leaves_the_previous_manifest_intact(monkeypatch: pytest.MonkeyPatch) -> None:
    snap = load(save(Region.empty(WORLD, BOX, STONE), "one"))
    stack = UndoStack()
    assert stack.push(snap, "fill") == 1

    def truncate_then_fail(self: Path, *args, **kwargs) -> int:
        with self.open("w"):
            pass
        raise OSError("disk full")

    with monkeypatch.context() as m:
        m.setattr(Path, "write_text", truncate_then_fail)
        with pytest.raises(OSError, match="disk full"):
            stack.push(snap, "fill")
    assert [e["id"] for e in stack.entries()] == [1]
    assert sorted(p.name for p in stack.manifest.parent.iterdir() if p.is_file()) == ["undo-manifest.json", "undo-manifest.json.tmp"]


def test_prune_with_dry_run_deletes_nothing(fake: FakeBridge, bridge: Bridge) -> None:
    region, stack = fetch_region(bridge, WORLD, BOX), UndoStack()
    old = load(save(region, "old", ts=datetime.now(UTC) - timedelta(days=15)))
    new = load(save(region, "new"))
    stack.push(old, "fill"), stack.push(new, "fill")
    assert stack.prune() == [old.path] and old.path.is_file() and [e["id"] for e in stack.entries()] == [1, 2]
    assert stack.prune(keep_days=30) == []
    assert stack.prune(dry_run=False) == [old.path] and not old.path.exists() and new.path.is_file()
    assert [e["id"] for e in stack.entries()] == [2]
