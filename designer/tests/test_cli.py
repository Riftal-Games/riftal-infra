import json

import pytest

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
