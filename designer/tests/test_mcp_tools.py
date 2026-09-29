import json
import shutil
from pathlib import Path
from typing import Any

import anyio
import numpy as np
import pytest
from mcp.shared.memory import create_connected_server_and_client_session
from PIL import Image

from designer import config, mcp_server
from designer.blocks import BlockClass
from designer.builders import BUILDERS
from designer.cli import main
from designer.region import Bounds
from designer.verify import Check
from designer.world_index import Location, NamedRegion, WorldEntry, WorldIndex
from tests.conftest import REFUSED_BUILDS, SMALL_MINE_NAMES, SMALL_MINE_SPEC, SMALL_ROAD_SPEC, SMALL_STAIRS_SPEC, STONE_PALETTES
from tests import fake_bridge
from tests.fake_bridge import FakeBridge, FakeWorld

PAD = Bounds((0, 63, 0), (7, 65, 7))
MUTATING = {
    "fill": {"target": "pad", "block": "glass"}, "replace": {"target": "pad", "from_block": "grass_block", "to_block": "dirt"},
    "set_blocks": {"blocks": [[0, 70, 0, "stone"]]}, "snapshot": {"target": "pad", "label": "x"}, "restore": {"snapshot": 1},
    "persist_mark": {"marker": "m", "at": "spawn"},
    "undo": {}, "list_snapshots": {}, "list_undo": {}, "terraform": {"target": "pad", "mode": "flatten", "level": 70},
    "build": {"kind": "mine", "spec": SMALL_MINE_SPEC, "palette": "mine_stone"},
    "spawn_npc": {"name": "n", "at": "spawn"}, "move_entity": {"id": "e1", "at": "spawn"}, "remove_entity": {"id": "e1"},
    "set_spawn": {"world": "design", "at": "spawn"}, "set_text": {"at": "spawn", "text": "hi"}, "remove_text": {"id": "t1"},
    "save_world": {"world": "design"}, "load_world": {"name": "design", "confirm": True},
    "create_world": {"name": "quarry", "generator": "normal", "seed": 1, "confirm": True},
    "pregen": {"world": "design", "min": [0, 0], "max": [15, 15], "confirm": True},
    "run_command": {"command": "say hi", "confirm": True},
}


@pytest.fixture
def server(fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> FakeBridge:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_HOST", "127.0.0.1")
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.delenv("DESIGNER_READ_ONLY", raising=False)
    index = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")])
    index.add_location(Location("spawn", "design", (0, 64, 0), tags=["spawn"]))
    index.add_region(NamedRegion("pad", "design", PAD.min, PAD.max))
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index.save(tmp_path / "index.json"))
    mcp_server.reset()
    yield fake
    mcp_server.reset()


def call(tool: str, /, **arguments: Any) -> dict[str, Any]:
    async def go() -> dict[str, Any]:
        _, result = await mcp_server.mcp.call_tool(tool, arguments)
        return result

    return anyio.run(go)


def test_server_status_reports_the_designer_flag_both_ways(server: FakeBridge) -> None:
    status = call("server_status")
    assert status["ok"] and status["connected"] and status["designer"] is True
    assert status["rtt_ms"] >= 0 and status["worlds"] == [{"name": "design", "loaded": True}]
    assert status["server_info"]["protocol"] == 2168

    server.designer = False
    assert call("server_status")["designer"] is False
    refused = anyio.run(mcp_server._run, mcp_server._ensure_designer)
    assert refused == {"ok": False, "error": mcp_server.NOT_DESIGNER, "code": "not_designer"}


def test_status_without_a_bridge_is_not_an_error(server: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DESIGNER_PORT", "1")
    mcp_server.reset()
    status = call("server_status")
    assert status["ok"] and status["connected"] is False and "cannot connect" in status["error"]


def test_metrics_reads_tps_tick_usage_and_memory_off_server_info(server: FakeBridge) -> None:
    result = call("metrics")
    assert result == {"ok": True, "tps": 20.0, "tps_avg": 19.8, "tick_usage": 0.12, "tick_usage_avg": 0.15, "memory_bytes": 123456789}


def test_heightmap_ascii_returns_the_map_with_its_header(server: FakeBridge) -> None:
    result = call("heightmap_ascii", at="spawn", size=32)
    assert result["ok"]
    assert result["text"].splitlines()[0] == "world=design x=-16..15 z=-16..15 y=63..63 band=1 step=1"
    assert "A spawn (0,64,0)" in result["text"] and result["summary"]["flat"] == 1.0
    assert "x=-128..127" in call("heightmap_ascii", at="0,0", size=1000)["text"]


def test_render_returns_a_path_under_reports_and_no_array(server: FakeBridge, tmp_path: Path) -> None:
    result = call("render", at="spawn", size=16)
    assert result["ok"] and set(result) == {"ok", "path", "summary"}
    path = Path(result["path"])
    assert path.parent == tmp_path / "reports" and path.suffix == ".png" and path.stat().st_size > 0
    assert not any(isinstance(v, list) for v in (*result.values(), *result["summary"].values()))
    assert result["summary"]["size"] == "16x16"
    assert call("render", at="spawn", kind="side")["ok"] is False


def test_render_isometric_reaches_isometric_png_and_writes_a_taller_image(server: FakeBridge, tmp_path: Path) -> None:
    topdown = call("render", at="spawn", size=16)
    isometric = call("render", at="spawn", size=16, kind="isometric")
    assert isometric["ok"] and set(isometric) == {"ok", "path", "summary"}
    path = Path(isometric["path"])
    assert path.parent == tmp_path / "reports" and path.suffix == ".png" and path.stat().st_size > 0
    assert path != Path(topdown["path"])
    # isometric_png's canvas is nz+nx blocks wide and tall, distinct from topdown_png's flat size*scale grid.
    assert Image.open(path).size != Image.open(Path(topdown["path"])).size


def test_timelapse_renders_one_frame_per_snapshot_taken_of_the_region(server: FakeBridge, tmp_path: Path) -> None:
    first = call("snapshot", target="pad", label="before")
    # fill's own target is "pad", so its automatic before-mutation snapshot is a third frame here.
    assert first["ok"] and call("fill", target="pad", block="glass")["ok"]
    second = call("snapshot", target="pad", label="after")
    assert second["ok"] and second["path"] != first["path"]

    result = call("timelapse", region="pad")
    assert result["ok"] and result["region"] == "pad" and result["world"] == "design" and result["frames"] == 3
    path = Path(result["path"])
    assert path.parent == tmp_path / "reports" and path.is_file() and path.name.startswith("timelapse-design-")


def test_timelapse_ignores_a_snapshot_taken_over_a_different_box(server: FakeBridge) -> None:
    assert call("snapshot", target={"min": [0, 70, 0], "max": [3, 70, 3]}, label="not_pad")["ok"]
    result = call("timelapse", region="pad")
    assert result["ok"] is False and "no snapshot of 'pad'" in result["error"]


def test_timelapse_refuses_a_location_name(server: FakeBridge) -> None:
    result = call("timelapse", region="spawn")
    assert result["ok"] is False and "is a location" in result["error"]


def test_inspect_caps_the_radius_and_slices_by_class(server: FakeBridge) -> None:
    result = call("inspect", at="16,63,16", radius=20)
    assert result["ok"] and result["bounds"] == {"min": [8, 55, 8], "max": [24, 71, 24]}
    assert len(result["slices"]) == 17 and len(result["slices"][0]["rows"]) == 17
    assert result["slices"][0]["y"] == 55 and result["slices"][0]["rows"][0] == "#" * 17
    assert result["slices"][-1]["rows"][0] == "." * 17
    assert result["counts"]["minecraft:grass_block"] == 17 * 17
    small = call("inspect", at="spawn", radius=1)
    assert small["center"] == [0, 64, 0] and len(small["slices"]) == 3
    assert call("inspect", at="4,4", radius=1)["center"] == [4, 63, 4]
    assert call("inspect", at="300,300", radius=1)["ok"] is False


@pytest.mark.parametrize("y", [-1, -10, FakeWorld.MIN_Y])
def test_inspect_at_a_column_whose_surface_is_below_zero_fills_its_y(server: FakeBridge, y: int) -> None:
    world = server.worlds["design"]
    world.edits[(300, y, 300)] = world.index_of("minecraft:stone")
    assert call("inspect", at="300,300", radius=1)["center"] == [300, y, 300]


def test_inspect_at_an_empty_column_beside_a_surface_below_zero_says_it_is_empty(server: FakeBridge) -> None:
    world = server.worlds["design"]
    world.edits[(300, -1, 300)] = world.index_of("minecraft:stone")
    assert call("inspect", at="300,300", radius=1)["center"] == [300, -1, 300]
    result = call("inspect", at="301,300", radius=1)
    assert result["ok"] is False and "column 301,300 in design is empty; give x,y,z" in result["error"]


def test_the_fake_bridge_refuses_an_inspect_box_that_leaves_the_build_range(server: FakeBridge) -> None:
    floor, ceiling = FakeWorld.MIN_Y, FakeWorld.MAX_Y
    for lo, hi in ((floor - 2, floor + 2), (ceiling - 2, ceiling + 2)):
        bounds = {"min": [14, lo, 14], "max": [18, hi, 18]}
        refused = server._dispatch({"op": "get_region", "args": {"world": "design", "bounds": bounds}})
        assert refused["ok"] is False and refused["code"] == "OUT_OF_WORLD"


@pytest.mark.parametrize(
    ("y", "lo", "hi"), [(FakeWorld.MIN_Y, FakeWorld.MIN_Y, FakeWorld.MIN_Y + 2), (FakeWorld.MAX_Y, FakeWorld.MAX_Y - 2, FakeWorld.MAX_Y)]
)
def test_inspect_at_the_build_floor_or_ceiling_stops_at_it(server: FakeBridge, y: int, lo: int, hi: int) -> None:
    result = call("inspect", at=f"16,{y},16", radius=2)
    assert result["ok"] is True and result["center"] == [16, y, 16]
    assert result["bounds"] == {"min": [14, lo, 14], "max": [18, hi, 18]}
    assert [s["y"] for s in result["slices"]] == list(range(lo, hi + 1))


@pytest.mark.parametrize("y", [FakeWorld.MIN_Y - 1, FakeWorld.MAX_Y + 1])
def test_inspect_centred_outside_the_build_range_is_refused(server: FakeBridge, y: int) -> None:
    result = call("inspect", at=f"16,{y},16", radius=2)
    assert result["ok"] is False and "outside the build range" in result["error"]
    assert server.requests == []


def test_inspect_resolves_a_spawn_that_is_only_a_tag(server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    index = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")])
    index.add_location(Location("design_spawn", "design", (8, 64, 8), tags=["spawn"]))
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index.save(tmp_path / "tagged.json"))
    mcp_server.reset()
    result = call("inspect", at="spawn", radius=1)
    assert result["ok"] is True and result["center"] == [8, 64, 8]
    assert call("inspect", at="ghost", radius=1) == {"ok": False, "error": "no such name 'ghost'", "code": None}


def test_define_region_round_trips_through_the_index_file(server: FakeBridge, tmp_path: Path) -> None:
    defined = call("define_region", name="pit", min=[8, 60, 8], max=[-8, 70, -8], world="design", tags=["mine"], meta={"rank": "A"})
    assert defined["ok"] and defined["entry"]["min"] == [-8, 60, -8] and defined["entry"]["max"] == [8, 70, 8]
    resolved = call("index_resolve", name="pit")
    assert resolved["kind"] == "region" and resolved["pos"] == [0, 65, 0] and resolved["entry"]["meta"] == {"rank": "A"}
    assert [r.name for r in WorldIndex.load(tmp_path / "index.json").regions] == ["pad", "pit"]
    assert call("index_list", kind="regions", tag="mine")["regions"][0]["name"] == "pit"
    listed = call("index_list", tag="spawn")
    assert set(listed) == {"ok", "default_world", "locations", "regions"} and listed["regions"] == []
    assert [l["name"] for l in listed["locations"]] == ["spawn"]
    assert call("define_region", name="pit", min=[0, 0, 0], max=[1, 1, 1], world="design")["ok"] is False


def test_define_location_then_index_remove(server: FakeBridge, tmp_path: Path) -> None:
    assert call("define_location", name="sell", pos=[3, 64, 3], world="design", yaw=90, tags=["npc"])["ok"]
    assert call("index_resolve", name="sell")["kind"] == "location"
    removed = call("index_remove", name="sell")
    assert removed["ok"] and removed["entry"]["name"] == "sell"
    assert "sell" not in WorldIndex.load(tmp_path / "index.json").names()
    assert call("define_location", name="nowhere", pos=[0, 0, 0], world="mars")["ok"] is False


def test_unknown_name_is_an_error_dict_and_never_raises(server: FakeBridge) -> None:
    result = call("index_resolve", name="spwan")
    assert result == {"ok": False, "error": "no such name 'spwan', did you mean 'spawn'?", "code": None}
    assert call("index_remove", name="ghost")["ok"] is False
    assert call("index_list", kind="save") == {"ok": False, "error": "kind must be one of worlds, locations, regions, not 'save'", "code": None}
    refused = call("index_list", kind="worlds", tag="spawn")
    assert refused["ok"] is False and refused["error"].startswith("worlds carry no tags")
    assert [w["name"] for w in call("index_list", kind="worlds")["worlds"]] == ["design"]
    failed = call("list_entities", world="mars")
    assert failed["ok"] is False and failed["code"] == "WORLD_NOT_FOUND"


def test_index_list_answers_as_the_cli_does(server: FakeBridge, capsys: pytest.CaptureFixture[str]) -> None:
    assert call("define_location", name="gate", pos=[1, 64, 1], world="design", tags=["spawn"])["ok"]
    for kind, tag in ((None, None), (None, "spawn"), ("locations", "spawn"), ("regions", None), ("worlds", None)):
        assert main(["index", "list", *(["--kind", kind] if kind else []), *(["--tag", tag] if tag else [])]) == 0
        listed = call("index_list", kind=kind, tag=tag)
        assert listed.pop("ok") is True and listed.pop("default_world") == "design"
        assert listed == json.loads(capsys.readouterr().out)
    assert main(["index", "list", "--kind", "worlds", "--tag", "spawn"]) == 1
    assert capsys.readouterr().err == f"designer: {call('index_list', kind='worlds', tag='spawn')['error']}\n"


def test_list_entities_and_tail_log_cap(server: FakeBridge) -> None:
    entities = call("list_entities", world="design")
    assert entities["ok"] and entities["count"] == 1 and entities["entities"][0]["name_tag"] == "hi"
    assert len(call("tail_log")["lines"]) == 50
    assert len(call("tail_log", lines=5000)["lines"]) == 200
    assert server.requests[-1]["args"] == {"n": 200}


@pytest.mark.parametrize("cls, glyph", [(BlockClass.AIR, "."), (BlockClass.SOLID, "#"), (BlockClass.LIQUID, "~"), (BlockClass.PASSABLE, ","), (BlockClass.DANGER, "!")])
def test_class_glyphs_are_pinned_to_the_enum(cls: BlockClass, glyph: str) -> None:
    assert mcp_server.CLASS_GLYPHS[cls] == glyph


def _writes(fake: FakeBridge) -> list[str]:
    return [r["op"] for r in fake.requests if r["op"] in ("set_blocks", "fill", "replace")]


def _pristine(fake: FakeBridge) -> bool:
    return bool(np.array_equal(fake.worlds["design"].blocks(PAD), FakeWorld().blocks(PAD)))


@pytest.mark.parametrize("name", [
    "fill", "replace", "set_blocks", "snapshot", "restore", "undo", "terraform", "build",
    "spawn_npc", "move_entity", "remove_entity", "set_spawn", "set_text", "remove_text",
    "save_world", "load_world", "create_world", "pregen", "run_command", "persist_mark",
])
def test_every_mutating_tool_is_refused_when_the_bridge_is_not_a_designer(server: FakeBridge, name: str) -> None:
    server.designer = False
    assert call(name, **MUTATING[name]) == {"ok": False, "error": mcp_server.NOT_DESIGNER, "code": "not_designer"}
    assert {r["op"] for r in server.requests} <= {"server_info"} and _pristine(server) and call("list_undo")["entries"] == []


def test_fill_that_fails_mid_send_still_answers_with_its_undo_entry(server: FakeBridge) -> None:
    result = call("fill", target="pad", block="bogus")
    assert result["ok"] is False and result["code"] == "BLOCK_INVALID" and result["undo_id"] == 1 and result["jobs"] == []
    assert Path(result["snapshot"]).is_file() and _writes(server) == ["fill"] and _pristine(server)
    assert [(e["id"], e["op"], e["path"]) for e in call("list_undo")["entries"]] == [(1, "fill", result["snapshot"])]


def test_read_only_switch_refuses_every_mutating_tool_before_the_bridge(server: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DESIGNER_READ_ONLY", "1")
    for name, arguments in MUTATING.items():
        assert call(name, **arguments) == {"ok": False, "error": mcp_server.READ_ONLY, "code": "read_only"}, name
    assert server.requests == [] and _pristine(server)


def test_fill_dry_run_changes_nothing_and_pushes_no_undo_entry(server: FakeBridge, tmp_path: Path) -> None:
    result = call("fill", **MUTATING["fill"], dry_run=True)
    assert result["ok"] and result["dry_run"] is True and result["blocks"] == 192 and result["bounds"] == PAD.to_json()
    assert result["snapshot"] is None and result["undo_id"] is None and result["jobs"] == []
    assert _writes(server) == [] and _pristine(server) and call("list_undo")["entries"] == []
    assert not (tmp_path / "snapshots").exists()


def test_fill_snapshots_first_and_list_undo_shows_it(server: FakeBridge, tmp_path: Path) -> None:
    result = call("fill", **MUTATING["fill"])
    assert result["ok"] and (result["blocks"], result["requests"], result["undo_id"]) == (192, 1, 1)
    snap = Path(result["snapshot"])
    assert snap.parent == tmp_path / "snapshots" / "design" and snap.name.endswith("-fill.npz") and snap.is_file()
    ops = [r["op"] for r in server.requests]
    assert ops.index("get_region") < ops.index("fill") and _writes(server) == ["fill"] and not _pristine(server)
    assert server.worlds["design"].blocks(PAD).min() == server.worlds["design"].palette.index("minecraft:glass")
    entries = call("list_undo")["entries"]
    assert [(e["id"], e["op"], e["restored"], e["session"], e["path"]) for e in entries] == [(1, "fill", False, mcp_server.SESSION, str(snap))]
    listed = call("list_snapshots", world="design")["snapshots"]
    assert [(s["path"], s["label"], s["undo_id"]) for s in listed] == [(str(snap), "fill", 1)]
    assert call("fill", target={"min": [0, 70, 0], "max": [3, 70, 3]}, block="stone")["undo_id"] == 2
    assert call("replace", **MUTATING["replace"])["undo_id"] == 3
    assert call("fill", target="spawn", block="stone")["ok"] is False


def test_fill_forwards_job_progress_from_the_worker_thread_to_the_client(server: FakeBridge) -> None:
    """``call()`` above never exercises ``_progress``'s live branch: ``mcp.call_tool`` outside a served
    request has no ``request_context``, so a real client session is the only way there.

    ``fill``'s own before-mutation snapshot fetches a region first, which is itself a job and would
    eat a plain ``queue_next`` before ``fill``'s job ever sees it; queuing only for the ``fill`` op
    keeps the two queued polls on the job this test means to watch.
    """
    real_job = server._job

    def queue_fill_only(op: str, result: dict[str, Any], steps: int = 0, total: int | None = None) -> dict[str, Any]:
        if op == "fill":
            server.queue_next = 2
        return real_job(op, result, steps=steps, total=total)

    server._job = queue_fill_only
    seen: list[tuple[float, float | None]] = []

    async def on_progress(progress: float, total: float | None, message: str | None) -> None:
        seen.append((progress, total))

    async def go() -> Any:
        async with create_connected_server_and_client_session(mcp_server.mcp) as session:
            return await session.call_tool("fill", {"target": "pad", "block": "glass"}, progress_callback=on_progress)

    result = anyio.run(go)
    assert result.isError is False and result.structuredContent["ok"] is True
    assert seen == [(0, 192), (96, 192), (192, 192)]


def test_undo_restores_the_fake(server: FakeBridge) -> None:
    assert call("fill", **MUTATING["fill"])["undo_id"] == 1 and not _pristine(server)
    dry = call("undo", dry_run=True)
    assert dry["ok"] and (dry["count"], dry["undone"], dry["blocks"], dry["undo_id"]) == (1, [], 0, None) and not _pristine(server)
    result = call("undo")
    assert result["ok"] and (result["count"], result["undone"], result["blocks"], result["undo_id"]) == (1, [1], 192, 2)
    assert dry["jobs"] == [] and len(result["jobs"]) == len(_writes(server)) - 1
    assert Path(result["snapshot"]).is_file() and _pristine(server)
    assert [(e["id"], e["op"], e["restored"]) for e in call("list_undo")["entries"]] == [(2, "undo", False), (1, "fill", True)]
    assert call("undo")["count"] == 0 and _pristine(server)


def test_restore_by_manifest_id_and_by_path(server: FakeBridge) -> None:
    first = call("fill", **MUTATING["fill"])
    assert first["undo_id"] == 1 and not _pristine(server)
    result = call("restore", snapshot=1)
    assert result["ok"] and (result["restored"], result["blocks"], result["undo_id"]) == (first["snapshot"], 192, 2)
    assert _pristine(server) and Path(result["snapshot"]).is_file()
    again = call("restore", snapshot=first["snapshot"])
    assert again["ok"] and (again["blocks"], again["snapshot"], again["undo_id"]) == (0, None, None)
    assert call("restore", snapshot="99")["ok"] is False and call("restore", snapshot="nope.npz")["ok"] is False
    assert [(e["id"], e["op"]) for e in call("list_undo")["entries"]] == [(2, "restore"), (1, "fill")]


def test_restore_refuses_a_path_outside_the_snapshots_dir(server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    taken = call("snapshot", **MUTATING["snapshot"])
    outside = Path(shutil.copy(taken["path"], tmp_path / "outside.npz"))
    monkeypatch.chdir(tmp_path / "snapshots")
    for ref in (str(outside), "../outside.npz"):
        refused = call("restore", snapshot=ref)
        assert refused["ok"] is False and "outside the snapshots directory" in refused["error"], ref
    assert _writes(server) == [] and call("restore", snapshot=taken["path"])["ok"] is True
    assert call("fill", **MUTATING["fill"])["undo_id"] == 1 and call("restore", snapshot=1)["ok"] is True and _pristine(server)
    bad = call("list_snapshots", world="../..")
    assert bad["ok"] is False and "world must match" in bad["error"]


def test_set_blocks_over_the_cap_is_refused_and_a_run_becomes_a_fill(server: FakeBridge) -> None:
    refused = call("set_blocks", blocks=[[x, 70, 0, "stone"] for x in range(4097)])
    assert refused["ok"] is False and "4096" in refused["error"] and _writes(server) == []
    result = call("set_blocks", blocks=[[x, 70, 0, "stone"] for x in range(8)] + [[0, 71, 0, "glass"]])
    assert result["ok"] and (result["blocks"], result["requests"], result["undo_id"]) == (9, 2, 1)
    assert _writes(server) == ["fill", "set_blocks"] and result["bounds"] == {"min": [0, 70, 0], "max": [7, 71, 0]}
    assert call("set_blocks", blocks=[])["ok"] is False


def test_persist_mark_writes_the_block_and_persist_verify_confirms_it(server: FakeBridge, tmp_path: Path) -> None:
    marked = call("persist_mark", marker="checkpoint", at="spawn")
    assert marked["ok"] and marked["block"] == "minecraft:diamond_block" and marked["pos"] == [0, 64, 0]
    assert marked["undo_id"] == 1 and Path(marked["snapshot"]).is_file()
    point = Bounds((0, 64, 0), (0, 64, 0))
    assert server.worlds["design"].blocks(point).item() == server.worlds["design"].palette.index("minecraft:diamond_block")

    manifest = tmp_path / "reports" / "persist-markers.json"
    assert json.loads(manifest.read_text())["checkpoint"] == {"world": "design", "pos": [0, 64, 0], "block": "minecraft:diamond_block"}

    verified = call("persist_verify", marker="checkpoint")
    assert verified == {
        "ok": True, "marker": "checkpoint", "world": "design", "pos": [0, 64, 0],
        "expected": "minecraft:diamond_block", "found": "minecraft:diamond_block", "passed": True,
    }
    missing = call("persist_verify", marker="ghost")
    assert missing["ok"] is False and "no persist_mark recorded" in missing["error"]


def test_persist_mark_dry_run_writes_nothing_and_records_no_marker(server: FakeBridge, tmp_path: Path) -> None:
    result = call("persist_mark", marker="m", at="spawn", dry_run=True)
    assert result["ok"] and result["dry_run"] is True and _writes(server) == []
    assert not (tmp_path / "reports" / "persist-markers.json").exists()


def test_persist_verify_fails_when_the_block_at_the_marker_has_changed(server: FakeBridge) -> None:
    call("persist_mark", marker="checkpoint", at="spawn")
    call("fill", target={"min": [0, 64, 0], "max": [0, 64, 0]}, block="stone")
    result = call("persist_verify", marker="checkpoint")
    assert result["ok"] and result["passed"] is False and result["found"] == "minecraft:stone"


def test_analyze_terrain_reads_the_flat_pad(server: FakeBridge) -> None:
    result = call("analyze_terrain", target="pad")
    assert result["ok"] and result["bounds"] == {"min": [0, 0], "max": [7, 7]}
    assert (result["columns"], result["min"], result["max"], result["mean"]) == (64, 63, 63, 63.0)
    assert result["water_fraction"] == 0.0 and result["flat_fraction"] == 1.0
    dict_target = call("analyze_terrain", target={"min": [0, 0], "max": [3, 3]})
    assert dict_target["ok"] and dict_target["columns"] == 16
    assert call("analyze_terrain", target="spawn")["ok"] is False


def test_find_flat_site_returns_a_site_on_the_flat_pad(server: FakeBridge) -> None:
    result = call("find_flat_site", target="pad", size=4, max_slope=0, max_range=0)
    assert result["ok"] and result["bounds"] == {"min": [0, 0], "max": [7, 7]}
    assert result["sites"] and result["sites"][0]["height"] == 63
    assert call("find_flat_site", target="pad", size=99)["ok"] is False


def test_terraform_snapshots_first_and_flattens_the_pad(server: FakeBridge, tmp_path: Path) -> None:
    dry = call("terraform", target="pad", mode="flatten", level=70, dry_run=True)
    assert dry["ok"] and dry["dry_run"] is True and dry["snapshot"] is None and _writes(server) == []
    result = call("terraform", target="pad", mode="flatten", level=70)
    assert result["ok"] and result["undo_id"] == 1 and result["bounds"] == {"min": [0, 64, 0], "max": [7, 70, 7]}
    snap = Path(result["snapshot"])
    assert snap.is_file() and not _pristine(server)
    flattened = call("analyze_terrain", target="pad")
    assert (flattened["min"], flattened["max"]) == (70, 70)
    assert call("undo")["ok"] and _pristine(server)


def test_terraform_target_by_dict_and_unknown_mode(server: FakeBridge) -> None:
    result = call("terraform", target={"min": [0, 0], "max": [3, 3]}, world="design", mode="raise", level=70)
    assert result["ok"] and result["bounds"] == {"min": [0, 64, 0], "max": [3, 70, 3]}
    assert call("terraform", target="pad", mode="dig", level=70) == {"ok": False, "error": "mode must be one of ('flatten', 'raise', 'lower', 'smooth'), got 'dig'", "code": None}


def test_build_dry_run_reports_index_entries_and_mine_valid_without_touching_the_bridge(server: FakeBridge) -> None:
    result = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="mine_stone", dry_run=True)
    assert result["ok"] and result["dry_run"] is True and result["world"] == "design"
    assert result["mine_valid"] == {"ok": True, "detail": "mine valid"}
    names = {e["name"] for e in (*result["locations"], *result["regions"])}
    assert names == SMALL_MINE_NAMES
    assert _writes(server) == []
    assert result["extras_report"] is None and not config.REPORTS_DIR.exists()


def test_build_dry_run_writes_no_extras_report_but_apply_does(server: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    dry = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone", dry_run=True)
    assert dry["ok"] and dry["dry_run"] is True and dry["extras_report"] is None
    assert not config.REPORTS_DIR.exists()

    result = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone")
    assert result["ok"] and result["dry_run"] is False
    report = Path(result["extras_report"])
    assert report.is_file() and report == config.REPORTS_DIR / "mine-tbox-extras.json"


def test_build_applies_registers_the_index_and_writes_the_extras_report(
    server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    result = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone")
    assert result["ok"] and result["undo_id"] == 1 and Path(result["snapshot"]).is_file()
    assert {l["name"] for l in call("index_list", kind="locations")["locations"]} >= {"tbox_exit", "tbox_spawn"}
    assert {r["name"] for r in call("index_list", kind="regions")["regions"]} >= {"tbox", "tbox_interior"}
    report = Path(result["extras_report"])
    assert report == tmp_path / "reports" / "mine-tbox-extras.json"
    assert json.loads(report.read_text())["mine_reset"]["reset_percent"] == 60


def test_build_refuses_to_overwrite_the_index_unless_replace_index(server: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    first = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone")
    assert first["ok"] and first["undo_id"] == 1

    again = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone")
    assert again["ok"] is False and "already defined" in again["error"]
    assert "snapshot" not in again and len(call("list_undo")["entries"]) == 1

    replaced = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone", replace_index=True)
    assert replaced["ok"] and replaced["undo_id"] == 2


@pytest.mark.parametrize("dry_run", [False, True])
def test_build_refuses_a_taken_name_before_any_edit_reaches_the_bridge(
    server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path, dry_run: bool
) -> None:
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    seeded = WorldIndex.load(tmp_path / "index.json")
    seeded.add_location(Location("tbox_spawn", "design", (0, 64, 0)))
    seeded.add_region(NamedRegion("tbox", "design", (0, 60, 0), (1, 61, 1)))
    seeded.save(tmp_path / "index.json")

    refused = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone", dry_run=dry_run)
    assert refused == {"ok": False, "error": "['tbox', 'tbox_spawn'] already defined; pass replace_index=True to overwrite", "code": None}
    assert _writes(server) == [] and call("list_undo")["entries"] == []
    assert not (tmp_path / "snapshots").exists() and not config.REPORTS_DIR.exists()
    assert call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone", dry_run=True, replace_index=True)["ok"] is True


@pytest.mark.parametrize("dry_run", [False, True])
def test_build_without_register_index_lets_a_taken_name_through_and_leaves_the_index_alone(
    server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path, dry_run: bool
) -> None:
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    seeded = WorldIndex.load(tmp_path / "index.json")
    seeded.add_location(Location("tbox_spawn", "design", (0, 64, 0)))
    seeded.add_region(NamedRegion("tbox", "design", (0, 60, 0), (1, 61, 1)))
    seeded.save(tmp_path / "index.json")
    before = (tmp_path / "index.json").read_bytes()

    built = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone", register_index=False, dry_run=dry_run)
    assert built["ok"] is True and "error" not in built
    assert (tmp_path / "index.json").read_bytes() == before


@pytest.mark.parametrize("replace_index", [False, True])
@pytest.mark.parametrize(("kind", "change", "error"), REFUSED_BUILDS)
def test_build_refuses_an_index_entry_before_any_edit_reaches_the_bridge(
    server: FakeBridge, refusable: FakeBridge, tmp_path: Path, kind: str, change: dict[str, Any], error: str, replace_index: bool,
) -> None:
    spec = {**SMALL_MINE_SPEC, **change}
    before = (tmp_path / "index.json").read_bytes()
    for dry_run in (True, False):
        refused = call("build", kind=kind, spec=spec, palette="test_stone", replace_index=replace_index, dry_run=dry_run)
        assert refused["ok"] is False and error in refused["error"]
    assert _writes(server) == [] and call("list_undo")["entries"] == []
    assert not (tmp_path / "snapshots").exists() and not config.REPORTS_DIR.exists()
    assert (tmp_path / "index.json").read_bytes() == before


def test_build_failing_mine_valid_sends_nothing_unless_verify_is_false(
    server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    monkeypatch.setattr("designer.mcp_server.mine_valid", lambda region, spec: Check(False, "interior open to the padding"))
    before = (tmp_path / "index.json").read_bytes()

    refused = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone")
    assert refused == {
        "ok": False, "code": None,
        "error": "mine_valid failed: interior open to the padding; nothing sent, pass verify=False to send it anyway",
    }
    assert _writes(server) == [] and call("list_undo")["entries"] == []
    assert not (tmp_path / "snapshots").exists() and not config.REPORTS_DIR.exists()
    assert (tmp_path / "index.json").read_bytes() == before

    dry = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone", dry_run=True)
    assert dry["ok"] is True and dry["mine_valid"] == {"ok": False, "detail": "interior open to the padding"}

    sent = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone", verify=False)
    assert sent["ok"] is True and sent["undo_id"] == 1 and sent["mine_valid"] is None and _writes(server) != []
    assert {r["name"] for r in call("index_list", kind="regions")["regions"]} >= {"tbox", "tbox_interior"}


def test_build_unknown_kind_and_a_spec_path_outside_specs_are_refused(server: FakeBridge) -> None:
    assert call("build", kind="bogus", spec=SMALL_MINE_SPEC, palette="mine_stone")["ok"] is False
    outside = call("build", kind="mine", spec="../outside.json", palette="mine_stone")
    assert outside["ok"] is False and "outside the specs directory" in outside["error"]


def test_build_road_dry_run_fetches_the_heightmap_and_reports_the_region(server: FakeBridge) -> None:
    result = call("build", kind="road", spec=SMALL_ROAD_SPEC, palette="mine_stone", dry_run=True)
    assert result["ok"] and result["dry_run"] is True and result["world"] == "design"
    assert result["regions"][0]["name"] == "test_road" and result["regions"][0]["tags"] == ["road", "walkway"]
    assert [r["op"] for r in server.requests if r["op"] != "server_info"] == ["get_heightmap"]


def test_build_road_applies_registers_the_region_and_writes_the_extras_report(server: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    result = call("build", kind="road", spec=SMALL_ROAD_SPEC, palette="test_stone")
    assert result["ok"] and Path(result["snapshot"]).is_file()
    assert {r["name"] for r in call("index_list", kind="regions")["regions"]} >= {"test_road"}
    assert Path(result["extras_report"]) == config.REPORTS_DIR / "road-test_road-extras.json"


def test_build_stairs_applies_with_no_name_and_falls_back_to_kind_for_the_report(server: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> None:
    """A spec with no ``name`` (every ``StairsSpec``, by design) must still apply and answer ``ok: True``.

    Regression for the MCP-only crash where ``build()`` reached for ``spec["name"]`` to name the
    extras report after the edits had already been sent, turning a real, applied build into an
    ``ok: False`` answer.
    """
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    result = call("build", kind="stairs", spec=SMALL_STAIRS_SPEC, palette="test_stone")
    assert result["ok"] is True and result["dry_run"] is False and result["undo_id"] == 1
    assert Path(result["snapshot"]).is_file() and _writes(server) == ["fill"] * 6
    assert result["locations"] == [] and result["regions"] == [] and result["mine_valid"] is None
    assert Path(result["extras_report"]) == config.REPORTS_DIR / "stairs-stairs-extras.json"


# Every registered kind with a spec small enough for the fake's flat pad, the names it indexes, and the name
# its extras report carries: a kind whose spec has no ``name`` reports under the kind itself.
BUILD_SPECS: dict[str, tuple[dict[str, Any], set[str], str]] = {
    "mine": (SMALL_MINE_SPEC, SMALL_MINE_NAMES, "tbox"),
    "road": (SMALL_ROAD_SPEC, {"test_road"}, "test_road"),
    "stairs": (SMALL_STAIRS_SPEC, set(), "stairs"),
    "platform": ({"name": "t_platform", "world": "design", "min": [0, 0], "max": [3, 3], "y": 64}, {"t_platform"}, "t_platform"),
    "plot_grid": (
        {"name": "t_plots", "world": "design", "origin": [0, 0], "y": 64, "rows": 1, "cols": 2, "plot_size": [3, 3], "buffer": 1},
        {"t_plots_0_0", "t_plots_0_1"}, "t_plots",
    ),
    "signage": ({"world": "design", "signs": [{"name": "t_sign", "pos": [0, 64, 0], "text": "hi"}]}, {"t_sign"}, "signage"),
    # No ``y``, so the perimeter reads the ground through the bridge's heightmap.
    "perimeter": ({"name": "t_fence", "world": "design", "min": [0, 0], "max": [4, 4], "height": 2, "post_every": 2}, {"t_fence"}, "t_fence"),
    "room": (
        {"name": "t_room", "world": "design", "origin": [0, 64, 0], "size": [5, 4, 5], "wall_thickness": 1,
         "door": {"side": "south", "width": 1, "height": 2}, "lights_every": 3},
        {"t_room", "t_room_door"}, "t_room",
    ),
}
ROLES = ("wall", "wall_trim", "floor", "ceiling", "sign", "road", "road_edge", "stairs", "slab", "plot_edge", "boundary", "boundary_accent")
EVERY_ROLE_PALETTES = {"colors": {}, "palettes": {"test_every_role": {**dict.fromkeys(ROLES, "minecraft:stone"), "light": "minecraft:lantern"}}}


@pytest.fixture
def every_role(server: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> FakeBridge:
    """``room`` sets its lights with ``hanging=false``, a state the fake's allowlist otherwise refuses."""
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: EVERY_ROLE_PALETTES)
    monkeypatch.setattr("tests.fake_bridge.ALLOWED_BLOCKS", fake_bridge.ALLOWED_BLOCKS | {"minecraft:lantern[hanging=false]"})
    return server


def _indexed() -> set[str]:
    return {e["name"] for kind in ("locations", "regions") for e in call("index_list", kind=kind)[kind]}


def test_build_specs_name_every_registered_kind() -> None:
    assert set(BUILD_SPECS) == set(BUILDERS)


BLOCK_KINDS = sorted(kind for kind in BUILD_SPECS if kind != "signage")


@pytest.mark.parametrize("kind", sorted(BUILD_SPECS))
def test_build_dry_run_of_every_kind_answers_its_names_and_touches_nothing(every_role: FakeBridge, tmp_path: Path, kind: str) -> None:
    spec, names, _ = BUILD_SPECS[kind]
    before, indexed = (tmp_path / "index.json").read_bytes(), _indexed()
    result = call("build", kind=kind, spec=spec, palette="test_every_role", dry_run=True)
    assert result["ok"] is True and result["dry_run"] is True and result["world"] == "design" and result["requests"] > 0, result
    assert (result["snapshot"], result["undo_id"], result["extras_report"]) == (None, None, None)
    assert {e["name"] for e in (*result["locations"], *result["regions"])} == names
    assert _writes(every_role) == [] and every_role.texts == {} and call("list_undo")["entries"] == []
    assert (tmp_path / "index.json").read_bytes() == before and _indexed() == indexed
    assert not (tmp_path / "snapshots").exists() and not config.REPORTS_DIR.exists()


def _assert_registered_and_reported(result: dict[str, Any], kind: str, indexed: set[str]) -> None:
    _, names, report_name = BUILD_SPECS[kind]
    assert {e["name"] for e in (*result["locations"], *result["regions"])} == names and _indexed() == indexed | names
    report = Path(result["extras_report"])
    assert report == config.REPORTS_DIR / f"{kind}-{report_name}-extras.json"
    assert {e["name"] for key in ("locations", "regions") for e in json.loads(report.read_text()).get(key, [])} == names


@pytest.mark.parametrize("kind", BLOCK_KINDS)
def test_build_apply_of_every_block_kind_registers_its_names_and_writes_its_extras_report(every_role: FakeBridge, kind: str) -> None:
    indexed = _indexed()
    result = call("build", kind=kind, spec=BUILD_SPECS[kind][0], palette="test_every_role")
    assert result["ok"] is True and result["dry_run"] is False and result["undo_id"] == 1, result
    assert Path(result["snapshot"]).is_file() and _writes(every_role)
    _assert_registered_and_reported(result, kind, indexed)


def test_build_apply_of_signage_places_its_text_with_no_snapshot_and_undo_removes_it(every_role: FakeBridge) -> None:
    indexed = _indexed()
    result = call("build", kind="signage", spec=BUILD_SPECS["signage"][0], palette="test_every_role")
    assert result["ok"] is True and result["dry_run"] is False and result["undo_id"] == 1, result
    assert (result["bounds"], result["snapshot"]) == (None, None) and _writes(every_role) == []
    assert list(config.SNAPSHOTS_DIR.rglob("*.npz")) == []
    assert every_role.texts == {"t_sign": {"world": "design", "pos": [0, 64, 0], "text": "hi"}}
    _assert_registered_and_reported(result, "signage", indexed)
    [entry] = call("list_undo")["entries"]
    assert (entry["id"], entry["op"], entry["path"], entry["texts"], entry["restored"]) == (1, "build_signage", None, ["t_sign"], False)
    undone = call("undo")
    assert undone["ok"] is True and undone["undone"] == [1] and undone["undo_id"] is None, undone
    assert every_role.texts == {} and [e["restored"] for e in call("list_undo")["entries"]] == [True]


def test_undo_of_signage_completes_when_its_text_is_already_gone_and_restore_refuses_the_entry(every_role: FakeBridge) -> None:
    assert call("build", kind="signage", spec=BUILD_SPECS["signage"][0], palette="test_every_role")["undo_id"] == 1
    assert "floating text with no snapshot" in call("restore", snapshot=1)["error"]
    assert call("remove_text", id="t_sign")["ok"] is True
    assert call("undo")["undone"] == [1] and every_role.texts == {}


def test_undo_reports_the_block_undo_entry_when_the_oldest_undone_entry_is_text(every_role: FakeBridge) -> None:
    assert call("build", kind="signage", spec=BUILD_SPECS["signage"][0], palette="test_every_role")["undo_id"] == 1
    assert call("fill", **MUTATING["fill"])["undo_id"] == 2
    result = call("undo", n=2)
    assert result["ok"] is True and result["undone"] == [2, 1] and result["undo_id"] == 3, result
    [entry] = [e for e in call("list_undo")["entries"] if e["id"] == 3]
    assert (entry["op"], entry["path"]) == ("undo", result["snapshot"]) and _pristine(every_role)


def _with_locations(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """A fresh index with ``far`` (reachable) and ``void`` (outside the fake terrain's extent), plus ``spawn``."""
    index = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")])
    index.add_location(Location("spawn", "design", (5, 64, 5), tags=["spawn"]))
    index.add_location(Location("far", "design", (10, 64, 10)))
    index.add_location(Location("void", "design", (-40, 64, -40)))
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index.save(tmp_path / "checks_index.json"))
    mcp_server.reset()


def test_check_path_passes_within_max_seconds_and_fails_when_too_slow(
    server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _with_locations(monkeypatch, tmp_path)
    passed = call("check_path", start="spawn", end="far")
    assert passed["ok"] and passed["passed"] and "blocks in" in passed["detail"]
    too_strict = call("check_path", start="spawn", end="far", max_seconds=0)
    assert too_strict["ok"] and too_strict["passed"] is False and "over 0 s" in too_strict["detail"]


def test_check_warp_safe_and_entity_clear_read_one_position(
    server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _with_locations(monkeypatch, tmp_path)
    assert call("check_warp_safe", at="spawn")["passed"] is True
    void = call("check_warp_safe", at="void")
    assert void["ok"] and void["passed"] is False and void["coords"] == [[-40, 63, -40]]
    assert call("check_entity_clear", at="spawn")["passed"] is True


def test_check_mine_validates_a_built_region(server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    monkeypatch.setattr("designer.checks.PROJECT_ROOT", tmp_path)
    spec_path = tmp_path / "specs" / "tbox.json"
    spec_path.parent.mkdir(parents=True, exist_ok=True)
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")
    assert call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone")["ok"]

    result = call("check_mine", region="tbox", spec="specs/tbox.json")
    assert result["ok"] and result["passed"] and result["detail"] == "mine valid"
    assert call("check_mine", region="tbox", spec="specs/nope.json")["passed"] is False


def test_run_checks_writes_the_report_and_counts_both_outcomes(server: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    text = "version: 1\nchecks:\n  - check: entity_clear\n    at: spawn\n  - check: warp_safe\n    at: void\n"
    monkeypatch.setattr("designer.checks.DEFAULT_PATH", tmp_path / "checks.yaml")
    (tmp_path / "checks.yaml").write_text(text, encoding="utf-8")

    result = call("run_checks")
    assert result["ok"] and (result["passed"], result["failed"], result["total"]) == (1, 1, 2)
    assert len(result["table"]) == 2 and Path(result["report"]).is_file()
    assert call("run_checks", only=["entity_clear_spawn"])["total"] == 1


def test_spawn_npc_move_and_remove_round_trip(server: FakeBridge) -> None:
    spawned = call("spawn_npc", name="Sellmaster", at="spawn", kind="villager", yaw=90, meta={"role": "sell"})
    assert spawned["ok"] and spawned["world"] == "design" and spawned["pos"] == [0, 64, 0]
    entity_id = spawned["entity_id"]
    assert spawned["npc_id"] == entity_id
    assert server.entities[entity_id]["name"] == "Sellmaster" and server.entities[entity_id]["yaw"] == 90

    moved = call("move_entity", id=entity_id, at="4,4")
    assert moved["ok"] and moved["pos"] == [4, 63, 4] and server.entities[entity_id]["pos"] == [4, 63, 4]

    removed = call("remove_entity", id=entity_id)
    assert removed == {"ok": True, "id": entity_id}
    assert entity_id not in server.entities
    assert call("remove_entity", id=entity_id)["code"] == "ENTITY_NOT_FOUND"


def test_set_spawn_reaches_the_named_world(server: FakeBridge) -> None:
    result = call("set_spawn", world="design", at="spawn")
    assert result["ok"] and result["pos"] == [0, 64, 0] and server.spawns["design"] == [0, 64, 0]
    assert call("set_spawn", world="mars", at="spawn")["code"] == "WORLD_NOT_FOUND"


def test_set_text_places_and_updates_then_remove_text_clears_it(server: FakeBridge) -> None:
    placed = call("set_text", at="spawn", text="Sell your ore here")
    assert placed["ok"] and placed["pos"] == [0, 64, 0] and placed["id"]
    text_id = placed["id"]
    assert server.texts[text_id]["text"] == "Sell your ore here"

    updated = call("set_text", at="spawn", text="Sell here", id=text_id)
    assert updated["ok"] and updated["id"] == text_id and server.texts[text_id]["text"] == "Sell here"

    assert call("remove_text", id=text_id) == {"ok": True, "id": text_id}
    assert call("remove_text", id=text_id)["code"] == "ENTITY_NOT_FOUND"


def test_save_load_and_create_world_gate_on_confirm(server: FakeBridge) -> None:
    assert call("save_world", world="design") == {"ok": True, "world": "design"}

    refused = call("load_world", name="design")
    assert refused == {"ok": False, "error": "load_world needs confirm=True", "code": "confirm_required"}
    loaded = call("load_world", name="design", confirm=True)
    assert loaded["ok"] and loaded["world"] == "design" and loaded["seed"] == 0

    refused_create = call("create_world", name="quarry", generator="normal", seed=7)
    assert refused_create["code"] == "confirm_required" and "quarry" not in server.worlds
    created = call("create_world", name="quarry", generator="normal", seed=7, confirm=True)
    assert created == {"ok": True, "world": "quarry", "generator": "normal", "seed": 7}
    assert "quarry" in server.worlds
    assert call("create_world", name="quarry", generator="normal", seed=7, confirm=True)["code"] == "WORLD_EXISTS"


def test_pregen_gates_on_confirm_and_reports_the_chunk_count(server: FakeBridge) -> None:
    refused = call("pregen", world="design", min=[0, 0], max=[31, 31])
    assert refused == {"ok": False, "error": "pregen needs confirm=True", "code": "confirm_required"}
    result = call("pregen", world="design", min=[0, 0], max=[31, 31], confirm=True)
    assert result["ok"] and result["bounds"] == {"min": [0, 0], "max": [31, 31]} and result["result"] == {"chunks": 4}


def test_run_command_gates_on_confirm_and_reaches_the_bridge(server: FakeBridge) -> None:
    refused = call("run_command", command="say hi")
    assert refused["code"] == "confirm_required" and "run_command" not in [r["op"] for r in server.requests]
    result = call("run_command", command="say hi", confirm=True)
    assert result == {"ok": True, "command": "say hi", "success": True, "output": ["ran say hi"]}


def test_every_tool_is_registered() -> None:
    names = {t.name for t in anyio.run(mcp_server.mcp.list_tools)}
    assert names == {
        "server_status", "metrics", "index_list", "index_resolve", "heightmap_ascii", "render", "timelapse", "inspect",
        "define_region", "define_location", "index_remove", "list_entities", "tail_log",
        "fill", "replace", "set_blocks", "persist_mark", "persist_verify", "snapshot", "restore", "undo", "list_snapshots", "list_undo",
        "analyze_terrain", "find_flat_site", "terraform", "build",
        "check_path", "check_warp_safe", "check_entity_clear", "check_mine", "run_checks",
        "spawn_npc", "move_entity", "remove_entity", "set_spawn", "set_text", "remove_text",
        "save_world", "load_world", "create_world", "pregen", "run_command",
    }
