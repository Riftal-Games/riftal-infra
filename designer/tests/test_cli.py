import json
from pathlib import Path

import pytest
from PIL import Image

from designer.cli import main
from designer.render import LEGEND_LINE
from designer.world_index import Location, WorldEntry, WorldIndex
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
