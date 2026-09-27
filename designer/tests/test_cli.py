import json
from pathlib import Path

import pytest
from PIL import Image

from designer.cli import main
from designer.render import LEGEND_LINE
from designer.world_index import Location, WorldEntry, WorldIndex
from tests.conftest import SMALL_MINE_NAMES, SMALL_MINE_SPEC, STONE_PALETTES
from tests.fake_bridge import FakeBridge


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

    assert main(args) == 0
    again = json.loads(capsys.readouterr().out)
    assert again["ok"] is False and "already defined" in again["error"] and Path(again["snapshot"]).is_file()


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


def test_build_rejects_an_unknown_kind(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as excinfo:
        main(["build", "road", "--spec", "x", "--palette", "mine_stone"])
    assert excinfo.value.code == 2
    assert "invalid choice: 'road'" in capsys.readouterr().err
