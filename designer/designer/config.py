"""Toolkit settings.

Each value is read from the process environment first and from ``.env`` in the
project root second. ``.env`` is untracked; ``.env.example`` documents its keys.

``DESIGNER_ROOT`` is the one exception: it is read from the process environment
only, because it locates the project root and therefore ``.env`` itself. It
defaults to the directory containing this package.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

PACKAGE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = Path(os.environ.get("DESIGNER_ROOT", PACKAGE_DIR.parent)).resolve()
# Beside this checkout, found from the code rather than DESIGNER_ROOT, which may point at a copy of the project.
SIBLING_GAME_DIR = PACKAGE_DIR.parents[2] / "riftal-game"
REPORTS_DIR = PROJECT_ROOT / "reports"
SNAPSHOTS_DIR = PROJECT_ROOT / "snapshots"
ENV_FILE = PROJECT_ROOT / ".env"

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 19140


class ConfigError(Exception):
    """A required setting is missing or malformed."""


@dataclass(frozen=True)
class Settings:
    token: str = field(repr=False)
    host: str
    port: int


def read_env_file(path: Path) -> dict[str, str]:
    """Parse ``KEY=VALUE`` lines. Blank lines and ``#`` comments are skipped."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def load_settings(
    env: Mapping[str, str] | None = None,
    env_file: Path | None = None,
) -> Settings:
    """Resolve settings from ``env`` (default ``os.environ``) then ``env_file``.

    An empty environment value counts as unset, so an exported ``DESIGNER_TOKEN=``
    does not shadow the value in ``.env``.
    """
    if env is None:
        env = os.environ
    if env_file is None:
        env_file = ENV_FILE
    file_values = read_env_file(env_file)

    def lookup(key: str) -> str | None:
        return env.get(key) or file_values.get(key) or None

    token = lookup("DESIGNER_TOKEN")
    if token is None:
        raise ConfigError(
            "DESIGNER_TOKEN is not set. Export it, or copy "
            f"{env_file.parent / '.env.example'} to {env_file} and fill in the token "
            "the DesignBridge plugin was started with."
        )

    port_text = lookup("DESIGNER_PORT") or str(DEFAULT_PORT)
    try:
        port = int(port_text)
    except ValueError:
        raise ConfigError(f"DESIGNER_PORT must be an integer, got {port_text!r}.") from None

    return Settings(
        token=token,
        host=lookup("DESIGNER_HOST") or DEFAULT_HOST,
        port=port,
    )
