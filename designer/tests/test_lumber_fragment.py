import json
import os
from pathlib import Path

import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT, SIBLING_GAME_DIR

FRAGMENTS = Path("mines") / "resources" / "worlds"

# MineDefinition::fromFragment in riftal-game rejects a fragment without any of these.
REQUIRED_KEYS = {"interior", "floor_y", "ores"}


def _fragment_path(zone: str) -> Path:
    """RiftalMines' fragment for ``zone``, from RIFTAL_GAME_DIR or the sibling checkout.

    CI checks out this repository alone and holds no token for the private riftal-game
    (riftal-infra#321), so only an absent default sibling skips. An explicit RIFTAL_GAME_DIR
    that lacks the file is a mistyped path, and passing on it would look like coverage.
    """
    explicit = os.environ.get("RIFTAL_GAME_DIR")
    if explicit:
        path = Path(explicit) / FRAGMENTS / f"{zone}.json"
        assert path.is_file(), f"RIFTAL_GAME_DIR is set but {path} does not exist"
        return path
    path = SIBLING_GAME_DIR / FRAGMENTS / f"{zone}.json"
    if not path.is_file():
        pytest.skip(f"no riftal-game checkout at {SIBLING_GAME_DIR}; set RIFTAL_GAME_DIR")
    return path


@pytest.mark.parametrize("zone", ["lumber", "quarry", "farm"])
def test_the_fragment_matches_what_build_mine_computes(zone: str) -> None:
    fragment = json.loads(_fragment_path(zone).read_text(encoding="utf-8"))
    spec = MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / f"{zone}.json").read_text(encoding="utf-8")))
    mine_reset = build_mine(spec, Palette.load("mine_stone")).extras["mine_reset"]
    missing = REQUIRED_KEYS - fragment.keys()
    assert not missing, f"fragment lacks keys MineDefinition requires: {sorted(missing)}"
    unknown = fragment.keys() - mine_reset.keys()
    assert not unknown, f"fragment carries keys build_mine does not compute: {sorted(unknown)}"
    assert {key: mine_reset[key] for key in fragment} == fragment
