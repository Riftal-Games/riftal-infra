import json
import shutil
from pathlib import Path
from typing import Any

import anyio
import numpy as np
import pytest

from designer import config, mcp_server
from designer.blocks import BlockClass
from designer.region import Bounds
from designer.world_index import Location, NamedRegion, WorldEntry, WorldIndex
from tests.conftest import SMALL_MINE_NAMES, SMALL_MINE_SPEC, STONE_PALETTES
from tests.fake_bridge import FakeBridge, FakeWorld

PAD = Bounds((0, 63, 0), (7, 65, 7))
MUTATING = {
    "fill": {"target": "pad", "block": "glass"}, "replace": {"target": "pad", "from_block": "grass_block", "to_block": "dirt"},
    "set_blocks": {"blocks": [[0, 70, 0, "stone"]]}, "snapshot": {"target": "pad", "label": "x"}, "restore": {"snapshot": 1},
    "undo": {}, "list_snapshots": {}, "list_undo": {}, "terraform": {"target": "pad", "mode": "flatten", "level": 70},
    "build": {"kind": "mine", "spec": SMALL_MINE_SPEC, "palette": "mine_stone"},
}


@pytest.fixture
def server(fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> FakeBridge:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_HOST", "127.0.0.1")
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.delenv("DESIGNER_READ_ONLY", raising=False)
    monkeypatch.setattr(config, "SNAPSHOTS_DIR", tmp_path / "snapshots")
    monkeypatch.setattr(config, "REPORTS_DIR", tmp_path / "reports")
    index = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")])
    index.add_location(Location("spawn", "design", (0, 64, 0), tags=["spawn"]))
    index.add_region(NamedRegion("pad", "design", PAD.min, PAD.max))
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index.save(tmp_path / "index.json"))
    monkeypatch.setattr("designer.render.REPORTS_DIR", tmp_path / "reports")
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


@pytest.mark.parametrize("name", ["fill", "replace", "set_blocks", "snapshot", "restore", "undo", "terraform", "build"])
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
    assert again["snapshot"] and again["undo_id"] == 2

    replaced = call("build", kind="mine", spec=SMALL_MINE_SPEC, palette="test_stone", replace_index=True)
    assert replaced["ok"] and replaced["undo_id"] == 3


def test_build_unknown_kind_and_a_spec_path_outside_specs_are_refused(server: FakeBridge) -> None:
    assert call("build", kind="road", spec=SMALL_MINE_SPEC, palette="mine_stone")["ok"] is False
    outside = call("build", kind="mine", spec="../outside.json", palette="mine_stone")
    assert outside["ok"] is False and "outside the specs directory" in outside["error"]


def test_every_tool_is_registered() -> None:
    names = {t.name for t in anyio.run(mcp_server.mcp.list_tools)}
    assert names == {
        "server_status", "index_list", "index_resolve", "heightmap_ascii", "render", "inspect",
        "define_region", "define_location", "index_remove", "list_entities", "tail_log",
        "fill", "replace", "set_blocks", "snapshot", "restore", "undo", "list_snapshots", "list_undo",
        "analyze_terrain", "find_flat_site", "terraform", "build",
    }
