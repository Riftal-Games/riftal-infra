import json
from pathlib import Path

import pytest

from designer import world_index
from designer.cli import main
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
    monkeypatch.setenv("DESIGNER_PORT", str(fake.port))

    assert main(["ping"]) == 0
    assert capsys.readouterr().out.startswith(f"pong from 127.0.0.1:{fake.port} in ")
    assert main(["info"]) == 0
    assert json.loads(capsys.readouterr().out)["designer"] is True


def test_index_commands_need_no_bridge(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["index", "list"]) == 0
    listing = json.loads(capsys.readouterr().out)
    assert set(listing) == {"worlds", "locations", "regions"} and len(listing["worlds"]) == 9
    assert main(["index", "list", "--tag", "spawn"]) == 0
    assert json.loads(capsys.readouterr().out) == {"locations": listing["locations"], "regions": []}
    assert main(["index", "resolve", "spawn"]) == 0
    assert json.loads(capsys.readouterr().out)["pos"] == [0, 64, 0]
    assert main(["index", "resolve", "spwan"]) == 1 and "did you mean 'spawn'" in capsys.readouterr().err


def test_index_reports_a_bad_file_without_a_traceback(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.setattr(world_index, "DEFAULT_PATH", tmp_path / "missing.json")
    assert main(["index", "list"]) == 1 and capsys.readouterr().err.startswith("designer: ")
