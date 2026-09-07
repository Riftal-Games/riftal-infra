import pytest

from designer.cli import main


def test_version_prints_name_and_version(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as excinfo:
        main(["--version"])

    assert excinfo.value.code == 0
    assert capsys.readouterr().out.strip() == "designer 0.1.0"


def test_no_arguments_returns_zero() -> None:
    assert main([]) == 0
