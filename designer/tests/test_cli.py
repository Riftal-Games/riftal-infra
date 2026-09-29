import json
from pathlib import Path
from typing import Any

import pytest
from PIL import Image

from designer import stack as stack_mod
from designer.bridge import Bridge
from designer.builders import BUILDERS
from designer.cli import main
from designer.edits import EditList
from designer.render import LEGEND_LINE
from designer.snapshot import UndoStack
from designer.verify import Check
from designer.world_index import Location, NamedRegion, WorldEntry, WorldIndex
from tests.conftest import REFUSED_BUILDS, SMALL_MINE_NAMES, SMALL_MINE_SPEC, SMALL_ROAD_SPEC, STONE_PALETTES
from tests.fake_bridge import FakeBridge


def _checks_index(tmp_path: Path) -> Path:
    index = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")])
    index.add_location(Location("a", "design", (10, 64, 10)))
    index.add_location(Location("b", "design", (20, 64, 20)))
    index.add_location(Location("void", "design", (-40, 64, -40)))
    return index.save(tmp_path / "index.json")


@pytest.fixture
def origin_spawn(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    # FakeWorld's terrain starts at the origin, so a spawn there straddles its edge.
    index = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")])
    index.add_location(Location("spawn", "design", (0, 64, 0), tags=["spawn"]))
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index.save(tmp_path / "index.json"))


def test_version_prints_name_and_version(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as excinfo:
        main(["--version"])

    assert excinfo.value.code == 0
    assert capsys.readouterr().out.strip() == "designer 0.1.0"


def test_no_arguments_returns_zero() -> None:
    assert main([]) == 0


def test_ping_and_info_use_the_configured_bridge(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_HOST", "127.0.0.1")
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))

    assert main(["ping"]) == 0
    assert capsys.readouterr().out.startswith(f"pong from 127.0.0.1:{fake.port} in ")
    assert main(["info"]) == 0
    assert json.loads(capsys.readouterr().out)["designer"] is True


# Distinctive enough that no error text contains it unless the CLI leaks the token.
SENTINEL_TOKEN = "sentinel-token-7f3a"


@pytest.mark.parametrize(("env", "error"), [
    ({}, "designer: DESIGNER_TOKEN is not set."),
    (
        {"DESIGNER_TOKEN": SENTINEL_TOKEN, "DESIGNER_PORT": "port"},
        "designer: DESIGNER_PORT must be an integer, got 'port'.",
    ),
    ({"DESIGNER_TOKEN": SENTINEL_TOKEN}, "designer: ping failed with AUTH: bad token"),
], ids=["missing-token", "bad-port", "bridge-refuses-token"])
def test_a_config_or_bridge_error_prints_one_line_and_exits_one(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path,
    env: dict[str, str], error: str,
) -> None:
    monkeypatch.setattr("designer.config.ENV_FILE", tmp_path / ".env")
    monkeypatch.delenv("DESIGNER_TOKEN", raising=False)
    monkeypatch.setenv("DESIGNER_HOST", "127.0.0.1")
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    for key, value in env.items():
        monkeypatch.setenv(key, value)

    assert main(["ping"]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.startswith(error)
    assert captured.err.count("\n") == 1
    assert SENTINEL_TOKEN not in captured.err


def test_index_commands_need_no_bridge(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["index", "list"]) == 0
    listing = json.loads(capsys.readouterr().out)
    assert set(listing) == {"worlds", "locations", "regions"} and len(listing["worlds"]) == 9
    assert main(["index", "list", "--tag", "spawn"]) == 0
    assert json.loads(capsys.readouterr().out) == {"locations": listing["locations"], "regions": []}
    assert main(["index", "resolve", "spawn"]) == 0
    assert json.loads(capsys.readouterr().out)["pos"] == [256, 70, 256]
    assert main(["index", "resolve", "spwan"]) == 1 and "did you mean 'spawn'" in capsys.readouterr().err


def test_index_list_refuses_a_tag_on_worlds(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["index", "list", "--kind", "worlds", "--tag", "spawn"]) == 1
    captured = capsys.readouterr()
    assert captured.out == "" and captured.err.startswith("designer: worlds carry no tags")


def test_index_reports_a_bad_file_without_a_traceback(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", tmp_path / "missing.json")
    assert main(["index", "list"]) == 1 and capsys.readouterr().err.startswith("designer: ")


@pytest.mark.parametrize("args", [
    ["index", "resolve", "spawn"],
    ["heightmap", "--at", "spawn", "--size", "8"],
    ["render", "topdown", "--at", "spawn", "--size", "8"],
    ["render", "slice", "--at", "spawn", "--size", "8", "--y", "64"],
    ["terrain", "analyze", "--at", "spawn", "--size", "8"],
    ["build", "mine", "--spec", "{spec}", "--palette", "mine_stone"],
    ["build", "mine", "--spec", "{spec}", "--palette", "mine_stone", "--apply"],
    ["checks", "run"],
], ids=["index-resolve", "heightmap", "render-topdown", "render-slice", "terrain-analyze", "build-dry-run", "build-apply", "checks-run"])
def test_every_command_reports_a_missing_index_in_one_line(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path, args: list[str]
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    missing = tmp_path / "missing.json"
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", missing)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")

    assert main([a.format(spec=spec_path) for a in args]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.startswith(f"designer: cannot read the world index {missing}: ") and captured.err.count("\n") == 1
    assert fake.requests == []


@pytest.mark.usefixtures("origin_spawn")
def test_heightmap_prints_the_map_with_header_and_legend(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))

    assert main(["heightmap", "--at", "spawn", "--size", "32"]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0] == "world=design x=-16..15 z=-16..15 y=63..63 band=1 step=1"
    assert "A spawn (0,64,0)" in lines and lines[-1].startswith("ramp ")
    assert fake.requests[-1]["args"] == {"world": "design", "bounds": {"min": [-16, -16], "max": [15, 15]}}
    assert main(["heightmap", "--at", "300,300", "--size", "4", "--band", "3", "--max-width", "2"]) == 0
    assert capsys.readouterr().out.splitlines()[0] == "world=design x=298..301 z=298..301 y=empty band=3 step=2"


def test_heightmap_spawn_falls_back_to_the_tag_and_bad_refs_exit_one(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    index = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")])
    index.add_location(Location("design_spawn", "design", (8, 64, 8), tags=["spawn"]))
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index.save(tmp_path / "index.json"))

    assert main(["heightmap", "--at", "spawn", "--size", "8"]) == 0
    assert "A design_spawn (8,64,8)" in capsys.readouterr().out.splitlines()
    assert main(["heightmap", "--at", "nowhere", "--size", "8"]) == 1
    assert capsys.readouterr().err == "designer: no such name 'nowhere'\n"
    assert main(["heightmap", "--at", "spawn", "--size", "8", "--world", "lost"]) == 1
    assert capsys.readouterr().err.startswith("designer: no such name 'spawn'")


def test_render_topdown_writes_the_png_and_prints_its_path_and_summary(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    out = tmp_path / "spawn.png"

    assert main(["render", "topdown", "--at", "spawn", "--size", "32", "--scale", "2", "--out", str(out)]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0] == str(out) and Image.open(out).size == (64, 64 + LEGEND_LINE)
    assert lines[1] == "size=32x32 columns=256 min=63 max=63 mean=63.0 water=0.0 flat=1.0"


def test_render_isometric_writes_the_png_and_prints_its_path_and_summary(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    out = tmp_path / "spawn-iso.png"

    assert main(["render", "isometric", "--at", "spawn", "--size", "8", "--scale", "2", "--out", str(out)]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0] == str(out) and out.is_file()
    assert Image.open(out).size == (2 * 2 * (8 + 8), 2 * (8 + 8))
    assert lines[1] == "size=8x8 columns=16 min=63 max=63 mean=63.0 water=0.0 flat=1.0"


@pytest.mark.usefixtures("origin_spawn")
def test_render_slice_writes_the_png_and_prints_its_path_and_block_counts(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    out = tmp_path / "spawn-slice.png"

    assert main(["render", "slice", "--at", "spawn", "--size", "4", "--y", "64", "--out", str(out)]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0] == str(out) and Image.open(out).size == (4 * 4, 4 * 4 + LEGEND_LINE)
    assert fake.requests[-1]["args"]["bounds"] == {"min": [-2, 63, -2], "max": [1, 64, 1]}


@pytest.mark.usefixtures("origin_spawn")
def test_terrain_analyze_prints_stats_for_the_flat_area(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))

    assert main(["terrain", "analyze", "--at", "spawn", "--size", "8"]) == 0
    stats = json.loads(capsys.readouterr().out)
    # spawn sits at the corner of FakeWorld's terrain extent, so only its x>=0,z>=0 quadrant is real ground.
    assert stats == {
        "world": "design", "bounds": {"min": [-4, -4], "max": [3, 3]}, "columns": 16,
        "min": 63, "max": 63, "mean": 63.0, "water_fraction": 0.0, "flat_fraction": 1.0,
    }


def test_terrain_find_site_ranks_by_the_near_flag(fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))

    assert main([
        "terrain", "find-site", "--at", "spawn", "--size", "16", "--site-size", "4",
        "--max-slope", "0", "--max-range", "0", "--near", "spawn", "--limit", "1",
    ]) == 0
    sites = json.loads(capsys.readouterr().out)
    assert len(sites) == 1 and sites[0]["height"] == 63 and sites[0]["score"] == 0.0


def test_terrain_terraform_defaults_to_a_dry_run_and_apply_sends_it(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))

    assert main(["terrain", "terraform", "--at", "spawn", "--size", "4", "--mode", "flatten", "--level", "70"]) == 0
    dry = json.loads(capsys.readouterr().out)
    assert dry["apply"] is False and dry["columns"] == 4 and "fill" not in [r["op"] for r in fake.requests]

    assert main(["terrain", "terraform", "--at", "spawn", "--size", "4", "--mode", "flatten", "--level", "70", "--apply"]) == 0
    applied = json.loads(capsys.readouterr().out)
    assert applied["apply"] is True and applied["ok"] is True and applied["snapshot"]
    assert Path(applied["snapshot"]).is_file() and "fill" in [r["op"] for r in fake.requests]


def test_terrain_terraform_apply_pushes_an_undo_entry_that_restores_the_ground(
    fake: FakeBridge, bridge: Bridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    args = ["terrain", "terraform", "--at", "spawn", "--size", "4", "--mode", "flatten", "--level", "70", "--apply"]

    assert main(args) == 0
    report = json.loads(capsys.readouterr().out)
    [entry] = UndoStack().entries()
    assert report["undo_id"] == 1 and (entry["id"], entry["op"], entry["path"]) == (1, "terraform", report["snapshot"])

    assert [r.ok for r in UndoStack().undo(bridge)] == [True]
    assert [(e["op"], e["restored"]) for e in UndoStack().entries()] == [("terraform", True), ("undo", False)]


def test_terrain_terraform_apply_refuses_an_empty_edit_list_and_sends_nothing(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))

    assert main(["terrain", "terraform", "--at", "300,300", "--size", "4", "--mode", "flatten", "--level", "70", "--apply"]) == 1
    captured = capsys.readouterr()
    assert captured.out == "" and captured.err == "designer: nothing to do: the edit list is empty\n"
    assert [r["op"] for r in fake.requests] == ["get_heightmap"] and UndoStack().entries() == []
    assert not (tmp_path / "snapshots").exists()


def test_terrain_terraform_apply_exits_one_when_the_bridge_refuses_an_edit(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))

    args = ["terrain", "terraform", "--at", "spawn", "--size", "4", "--mode", "flatten", "--level", "70", "--block", "minecraft:bogus"]
    assert main(args) == 0
    assert json.loads(capsys.readouterr().out)["apply"] is False

    assert main([*args, "--apply"]) == 1
    captured = capsys.readouterr()
    report = json.loads(captured.out)
    assert report["ok"] is False and "unknown block 'minecraft:bogus'" in report["error"] and Path(report["snapshot"]).is_file()
    assert captured.err == f"designer: apply failed: {report['error']}\n"


def test_terrain_terraform_rejects_an_unknown_mode(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as excinfo:
        main(["terrain", "terraform", "--at", "spawn", "--size", "4", "--mode", "dig"])
    assert excinfo.value.code == 2
    assert "invalid choice: 'dig'" in capsys.readouterr().err


def test_build_dry_run_reports_index_entries_and_mine_valid_without_touching_the_bridge(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")

    assert main(["build", "mine", "--spec", str(spec_path), "--palette", "mine_stone"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["kind"] == "mine" and report["world"] == "design" and report["apply"] is False
    assert report["mine_valid"] == {"ok": True, "detail": "mine valid"}
    names = {e["name"] for e in (*report["locations"], *report["regions"])}
    assert names == SMALL_MINE_NAMES
    assert fake.requests == []


def test_build_apply_registers_the_index_then_refuses_the_second_apply(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")
    args = ["build", "mine", "--spec", str(spec_path), "--palette", "test_stone", "--apply"]

    assert main(args) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["ok"] is True and Path(report["snapshot"]).is_file()
    assert {e.name for e in (*WorldIndex.load(index_path).locations, *WorldIndex.load(index_path).regions)} == SMALL_MINE_NAMES

    assert main(args) == 1
    again = capsys.readouterr()
    assert again.out == "" and "already defined" in again.err


@pytest.mark.parametrize("apply", [[], ["--apply"]], ids=["dry-run", "apply"])
def test_build_refuses_a_taken_name_before_any_edit_reaches_the_bridge(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path, apply: list[str]
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    seeded = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")])
    seeded.add_location(Location("tbox_spawn", "design", (0, 64, 0)))
    seeded.add_region(NamedRegion("tbox", "design", (0, 60, 0), (1, 61, 1)))
    index_path = seeded.save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")

    assert main(["build", "mine", "--spec", str(spec_path), "--palette", "test_stone", *apply]) == 1
    refused = capsys.readouterr()
    assert refused.out == "" and refused.err.startswith("designer: ['tbox', 'tbox_spawn'] already defined")
    assert [r["op"] for r in fake.requests if r["op"] in ("set_blocks", "fill", "replace")] == []
    assert not (tmp_path / "snapshots").exists() and not (tmp_path / "reports").exists()
    assert WorldIndex.load(index_path).to_json() == seeded.to_json()
    assert main(["build", "mine", "--spec", str(spec_path), "--palette", "test_stone", "--no-index"]) == 0


@pytest.mark.parametrize("apply", [[], ["--apply"]], ids=["dry-run", "apply"])
@pytest.mark.parametrize(("kind", "change", "error"), REFUSED_BUILDS)
def test_build_refuses_an_index_entry_before_any_edit_reaches_the_bridge(
    refusable: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path,
    kind: str, change: dict[str, Any], error: str, apply: list[str],
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", refusable.token)
    monkeypatch.setenv("DESIGNER_PORT", str(refusable.port))
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    before = index_path.read_bytes()
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps({**SMALL_MINE_SPEC, **change}), encoding="utf-8")

    assert main(["build", kind, "--spec", str(spec_path), "--palette", "test_stone", *apply]) == 1
    refused = capsys.readouterr()
    assert refused.out == "" and error in refused.err
    assert [r["op"] for r in refusable.requests if r["op"] in ("set_blocks", "fill", "replace")] == []
    assert not (tmp_path / "snapshots").exists() and not (tmp_path / "reports").exists()
    assert index_path.read_bytes() == before


def test_build_apply_writes_the_extras_report_matching_the_mcp_build_tool(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")

    assert main(["build", "mine", "--spec", str(spec_path), "--palette", "test_stone"]) == 0
    dry = json.loads(capsys.readouterr().out)
    assert dry["extras_report"] is None and not (tmp_path / "reports").exists()

    assert main(["build", "mine", "--spec", str(spec_path), "--palette", "test_stone", "--apply"]) == 0
    applied = json.loads(capsys.readouterr().out)
    report_path = Path(applied["extras_report"])
    assert report_path == tmp_path / "reports" / "mine-tbox-extras.json"
    assert json.loads(report_path.read_text())["mine_reset"]["reset_percent"] == 60


def test_build_no_verify_and_no_index_skip_their_steps(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")

    assert main(["build", "mine", "--spec", str(spec_path), "--palette", "test_stone", "--no-verify"]) == 0
    assert "mine_valid" not in json.loads(capsys.readouterr().out)
    assert main(["build", "mine", "--spec", str(spec_path), "--palette", "test_stone", "--apply", "--no-index"]) == 0
    applied = json.loads(capsys.readouterr().out)
    assert applied["ok"] is True and WorldIndex.load(index_path).locations == []


def test_build_apply_exits_one_and_registers_nothing_when_the_bridge_refuses_an_edit(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    bogus = {"colors": {}, "palettes": {"test_stone": dict.fromkeys(STONE_PALETTES["palettes"]["test_stone"], "minecraft:bogus")}}
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: bogus)
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")
    args = ["build", "mine", "--spec", str(spec_path), "--palette", "test_stone", "--no-verify"]

    assert main(args) == 0
    capsys.readouterr()
    assert main([*args, "--apply"]) == 1
    captured = capsys.readouterr()
    report = json.loads(captured.out)
    assert report["ok"] is False and "unknown block 'minecraft:bogus'" in report["error"]
    assert captured.err == f"designer: apply failed: {report['error']}\n"
    assert WorldIndex.load(index_path).locations == [] and WorldIndex.load(index_path).regions == []


@pytest.mark.parametrize("apply", [[], ["--apply"]], ids=["dry-run", "apply"])
def test_build_exits_one_when_mine_valid_fails(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path, apply: list[str]
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    monkeypatch.setattr("designer.cli.mine_valid", lambda region, spec: Check(False, "interior open to the padding"))
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")

    before = index_path.read_bytes()

    assert main(["build", "mine", "--spec", str(spec_path), "--palette", "test_stone", *apply]) == 1
    captured = capsys.readouterr()
    report = json.loads(captured.out)
    assert report["mine_valid"] == {"ok": False, "detail": "interior open to the padding"}
    refused = "; nothing sent, --no-verify sends it anyway" if apply else ""
    assert captured.err == f"designer: mine_valid failed: interior open to the padding{refused}\n"
    assert "snapshot" not in report and "ok" not in report and report["extras_report"] is None
    assert [r["op"] for r in fake.requests if r["op"] in ("set_blocks", "fill", "replace")] == []
    assert not (tmp_path / "snapshots").exists() and not (tmp_path / "reports").exists()
    assert index_path.read_bytes() == before


def test_build_apply_with_no_verify_sends_and_registers_a_mine_mine_valid_would_fail(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    monkeypatch.setattr("designer.cli.mine_valid", lambda region, spec: Check(False, "interior open to the padding"))
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_MINE_SPEC), encoding="utf-8")

    assert main(["build", "mine", "--spec", str(spec_path), "--palette", "test_stone", "--apply", "--no-verify"]) == 0
    captured = capsys.readouterr()
    report = json.loads(captured.out)
    assert captured.err == "" and report["ok"] is True and Path(report["snapshot"]).is_file()
    assert [r for r in fake.requests if r["op"] in ("set_blocks", "fill", "replace")] != []
    assert {e.name for e in (*WorldIndex.load(index_path).locations, *WorldIndex.load(index_path).regions)} == SMALL_MINE_NAMES


def test_build_rejects_an_unknown_kind(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as excinfo:
        main(["build", "bogus", "--spec", "x", "--palette", "mine_stone"])
    assert excinfo.value.code == 2
    assert "invalid choice: 'bogus'" in capsys.readouterr().err


def test_build_road_dry_run_fetches_the_heightmap_and_reports_no_apply(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    spec_path = tmp_path / "spec.json"
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    spec_path.write_text(json.dumps(SMALL_ROAD_SPEC), encoding="utf-8")

    assert main(["build", "road", "--spec", str(spec_path), "--palette", "mine_stone"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["kind"] == "road" and report["world"] == "design" and report["apply"] is False
    assert report["regions"][0]["name"] == "test_road" and report["regions"][0]["tags"] == ["road", "walkway"]
    assert [r["op"] for r in fake.requests] == ["get_heightmap"]


def test_build_road_apply_sends_the_edits_and_registers_the_region(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setattr("designer.builders.base.load_palettes", lambda: STONE_PALETTES)
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(SMALL_ROAD_SPEC), encoding="utf-8")

    assert main(["build", "road", "--spec", str(spec_path), "--palette", "test_stone", "--apply"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["ok"] is True and Path(report["snapshot"]).is_file()
    assert {e.name for e in WorldIndex.load(index_path).regions} == {"test_road"}
    entries = UndoStack().entries()
    assert report["undo_id"] == 1 and [(e["id"], e["op"], e["path"]) for e in entries] == [(1, "build_road", report["snapshot"])]


def test_build_apply_of_signage_sends_its_text_and_an_undo_removes_it(
    fake: FakeBridge, bridge: Bridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    index_path = WorldIndex(worlds=[WorldEntry("design", "normal", 0, "design")]).save(tmp_path / "index.json")
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", index_path)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps({"world": "design", "signs": [{"name": "t_sign", "pos": [0, 64, 0], "text": "hi"}]}), encoding="utf-8")

    assert main(["build", "signage", "--spec", str(spec_path), "--palette", "mine_stone", "--apply"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["ok"] is True and report["bounds"] is None and report["snapshot"] is None and report["undo_id"] == 1
    assert fake.texts == {"t_sign": {"world": "design", "pos": [0, 64, 0], "text": "hi"}}
    assert {e.name for e in WorldIndex.load(index_path).locations} == {"t_sign"}
    assert Path(report["extras_report"]).is_file()
    [entry] = UndoStack().entries()
    assert (entry["id"], entry["op"], entry["path"], entry["texts"]) == (1, "build_signage", None, ["t_sign"])

    assert [r.ok for r in UndoStack().undo(bridge)] == [True]
    assert fake.texts == {} and [e["restored"] for e in UndoStack().entries()] == [True]


def test_build_apply_refuses_an_empty_edit_list_and_sends_nothing(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setitem(BUILDERS, "empty", lambda spec, palette, fetch: EditList("design", []))
    spec_path = tmp_path / "spec.json"
    spec_path.write_text("{}", encoding="utf-8")

    assert main(["build", "empty", "--spec", str(spec_path), "--palette", "mine_stone", "--no-index", "--apply"]) == 1
    captured = capsys.readouterr()
    assert captured.out == "" and captured.err == "designer: nothing to do: the edit list is empty\n"
    assert fake.requests == [] and UndoStack().entries() == []
    assert not (tmp_path / "snapshots").exists() and not (tmp_path / "reports").exists()


def test_checks_run_prints_the_table_and_exits_zero_when_all_pass(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", _checks_index(tmp_path))
    checks_path = tmp_path / "checks.yaml"
    checks_path.write_text("version: 1\nchecks:\n  - check: travel_time\n    from: a\n    to: b\n", encoding="utf-8")

    assert main(["checks", "run", "--path", str(checks_path)]) == 0
    out = capsys.readouterr().out
    assert "1 passed, 0 failed of 1." in out and "travel_time_a_b | travel_time | yes" in out
    assert (tmp_path / "reports").is_dir()


def test_checks_run_exits_one_on_a_failure_and_only_narrows_it(
    fake: FakeBridge, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    monkeypatch.setenv("DESIGNER_TOKEN", fake.token)
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))
    monkeypatch.setattr("designer.world_index.DEFAULT_PATH", _checks_index(tmp_path))
    checks_path = tmp_path / "checks.yaml"
    checks_path.write_text(
        "version: 1\nchecks:\n  - check: travel_time\n    from: a\n    to: b\n  - check: warp_safe\n    at: void\n    id: warp_void\n",
        encoding="utf-8",
    )

    assert main(["checks", "run", "--path", str(checks_path)]) == 1
    assert "1 passed, 1 failed of 2." in capsys.readouterr().out

    assert main(["checks", "run", "--path", str(checks_path), "--only", "travel_time_a_b"]) == 0
    assert "1 passed, 0 failed of 1." in capsys.readouterr().out


def test_stack_subcommands_dispatch_and_report_stack_errors(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    calls: list[tuple[str, ...]] = []
    monkeypatch.setattr("designer.cli.stack_mod.runtime_name", lambda: "docker")
    monkeypatch.setattr("designer.cli.stack_mod.up", lambda runtime: calls.append(("up", runtime)))
    monkeypatch.setattr("designer.cli.stack_mod.down", lambda runtime: calls.append(("down", runtime)))
    monkeypatch.setattr("designer.cli.stack_mod.logs", lambda runtime: "log output")
    monkeypatch.setattr("designer.cli.stack_mod.console", lambda runtime, line: calls.append(("console", runtime, line)))
    monkeypatch.setattr("designer.cli.stack_mod.build_image", lambda runtime: calls.append(("build-image",)))

    assert main(["stack", "up"]) == 0
    assert main(["stack", "down"]) == 0
    assert main(["stack", "logs"]) == 0
    assert main(["stack", "console", "say hello"]) == 0
    assert main(["stack", "build-image"]) == 0
    assert calls == [("up", "docker"), ("down", "docker"), ("console", "docker", "say hello"), ("build-image",)]
    assert capsys.readouterr().out == "up\ndown\nlog output\nsent: say hello\nbuilt local-pocketmine-mp\n"

    def boom(runtime: str) -> None:
        raise stack_mod.StackError("no running designer container")

    monkeypatch.setattr("designer.cli.stack_mod.up", boom)
    assert main(["stack", "up"]) == 1
    assert "designer: no running designer container" in capsys.readouterr().err
