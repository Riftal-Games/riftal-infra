from pathlib import Path

import pytest

from designer.config import DEFAULT_HOST, DEFAULT_PORT, ConfigError, Settings, load_settings


def write_env(tmp_path: Path, text: str) -> Path:
    path = tmp_path / ".env"
    path.write_text(text, encoding="utf-8")
    return path


def test_environment_wins_over_env_file(tmp_path: Path) -> None:
    env_file = write_env(tmp_path, "DESIGNER_TOKEN=from-file\nDESIGNER_HOST=file.host\n")
    env = {"DESIGNER_TOKEN": "from-env", "DESIGNER_HOST": "env.host"}

    settings = load_settings(env=env, env_file=env_file)

    assert settings.token == "from-env"
    assert settings.host == "env.host"


def test_env_file_is_parsed(tmp_path: Path) -> None:
    env_file = write_env(
        tmp_path,
        "# comment\n\nDESIGNER_TOKEN = 'secret'\nDESIGNER_HOST=\"10.0.0.5\"\nDESIGNER_PORT=19141\n",
    )

    settings = load_settings(env={}, env_file=env_file)

    assert settings == Settings(token="secret", host="10.0.0.5", port=19141)


def test_missing_token_raises_config_error(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match=r"\.env\.example"):
        load_settings(env={}, env_file=tmp_path / ".env")


def test_empty_environment_token_falls_back_to_env_file(tmp_path: Path) -> None:
    env_file = write_env(tmp_path, "DESIGNER_TOKEN=from-file\n")

    settings = load_settings(env={"DESIGNER_TOKEN": ""}, env_file=env_file)

    assert settings.token == "from-file"


def test_port_is_an_int(tmp_path: Path) -> None:
    env = {"DESIGNER_TOKEN": "t", "DESIGNER_PORT": "19150"}

    settings = load_settings(env=env, env_file=tmp_path / ".env")

    assert settings.port == 19150
    assert type(settings.port) is int


def test_non_numeric_port_raises_config_error(tmp_path: Path) -> None:
    env = {"DESIGNER_TOKEN": "t", "DESIGNER_PORT": "nineteen"}

    with pytest.raises(ConfigError, match="DESIGNER_PORT"):
        load_settings(env=env, env_file=tmp_path / ".env")


def test_host_and_port_default(tmp_path: Path) -> None:
    settings = load_settings(env={"DESIGNER_TOKEN": "t"}, env_file=tmp_path / ".env")

    assert settings.host == DEFAULT_HOST
    assert settings.port == DEFAULT_PORT
