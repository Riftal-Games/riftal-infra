import json
import os
from pathlib import Path

import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT

SPEC_PATH = PROJECT_ROOT / "specs" / "mine_a.json"
INDEX_PATH = PROJECT_ROOT / "world_index.json"
FRAGMENT = Path("mines") / "resources" / "worlds" / "mine_a.json"
SIBLING_GAME_DIR = Path(__file__).resolve().parents[3] / "riftal-game"


def _fragment() -> dict:
    """RiftalMines' mine_a fragment, from RIFTAL_GAME_DIR or the sibling checkout.

    Same rule as the lumber fragment: only an absent default sibling skips, since CI has no
    riftal-game checkout (riftal-infra#321). An explicit RIFTAL_GAME_DIR lacking the file fails.
    """
    explicit = os.environ.get("RIFTAL_GAME_DIR")
    if explicit:
        path = Path(explicit) / FRAGMENT
        assert path.is_file(), f"RIFTAL_GAME_DIR is set but {path} does not exist"
    else:
        path = SIBLING_GAME_DIR / FRAGMENT
        if not path.is_file():
            pytest.skip(f"no riftal-game checkout at {SIBLING_GAME_DIR}; set RIFTAL_GAME_DIR")
    return json.loads(path.read_text(encoding="utf-8"))


def _mine_reset() -> dict:
    spec = MineSpec.from_dict(json.loads(SPEC_PATH.read_text(encoding="utf-8")))
    return build_mine(spec, Palette.load("mine_stone")).extras["mine_reset"]


def test_mine_a_fragment_matches_what_build_mine_computes() -> None:
    fragment = _fragment()
    mine_reset = _mine_reset()
    # RiftalMines reads only "ores", so a layer here would vanish at the first reset.
    assert mine_reset.pop("ore_layers") == []
    assert "interior" in fragment
    assert {key: value for key, value in fragment.items() if key != "rank"} == mine_reset


def test_mine_a_fragment_rank_matches_the_world_index() -> None:
    fragment = _fragment()
    worlds = json.loads(INDEX_PATH.read_text(encoding="utf-8"))["worlds"]
    assert fragment["rank"] == next(w["rank"] for w in worlds if w["name"] == "mine_a")
