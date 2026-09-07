from pathlib import Path
from typing import Any

import anyio
import pytest

from designer import mcp_server
from designer.blocks import BlockClass
from designer.world_index import Location, WorldEntry, WorldIndex
from tests.fake_bridge import FakeBridge


@pytest.fixture
def server(fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> FakeBridge:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_HOST", "127.0.0.1")
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    index = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")])
    index.add_location(Location("spawn", "design", (0, 64, 0), tags=["spawn"]))
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


def test_define_region_round_trips_through_the_index_file(server: FakeBridge, tmp_path: Path) -> None:
    defined = call("define_region", name="pit", min=[8, 60, 8], max=[-8, 70, -8], world="design", tags=["mine"], meta={"rank": "A"})
    assert defined["ok"] and defined["entry"]["min"] == [-8, 60, -8] and defined["entry"]["max"] == [8, 70, 8]
    resolved = call("index_resolve", name="pit")
    assert resolved["kind"] == "region" and resolved["pos"] == [0, 65, 0] and resolved["entry"]["meta"] == {"rank": "A"}
    assert [r.name for r in WorldIndex.load(tmp_path / "index.json").regions] == ["pit"]
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


def test_every_tool_is_registered() -> None:
    names = {t.name for t in anyio.run(mcp_server.mcp.list_tools)}
    assert names == {
        "server_status", "index_list", "index_resolve", "heightmap_ascii", "render", "inspect",
        "define_region", "define_location", "index_remove", "list_entities", "tail_log",
    }
