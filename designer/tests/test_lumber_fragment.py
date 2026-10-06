import json
import os
from pathlib import Path

import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT, SIBLING_GAME_DIR

SPEC_PATH = PROJECT_ROOT / "specs" / "lumber.json"
FRAGMENT = Path("mines") / "resources" / "worlds" / "lumber.json"


def _fragment_path() -> Path:
    """RiftalMines' lumber fragment, from RIFTAL_GAME_DIR or the sibling checkout.

    CI checks out this repository alone and holds no token for the private riftal-game
    (riftal-infra#321), so only an absent default sibling skips. An explicit RIFTAL_GAME_DIR
    that lacks the file is a mistyped path, and passing on it would look like coverage.
    """
    explicit = os.environ.get("RIFTAL_GAME_DIR")
    if explicit:
        path = Path(explicit) / FRAGMENT
        assert path.is_file(), f"RIFTAL_GAME_DIR is set but {path} does not exist"
        return path
    path = SIBLING_GAME_DIR / FRAGMENT
    if not path.is_file():
        pytest.skip(f"no riftal-game checkout at {SIBLING_GAME_DIR}; set RIFTAL_GAME_DIR")
    return path


def test_lumber_fragment_matches_what_build_mine_computes() -> None:
    fragment = json.loads(_fragment_path().read_text(encoding="utf-8"))
    spec = MineSpec.from_dict(json.loads(SPEC_PATH.read_text(encoding="utf-8")))
    mine_reset = build_mine(spec, Palette.load("mine_stone")).extras["mine_reset"]
    assert "interior" in fragment
    assert {key: mine_reset[key] for key in fragment} == fragment
