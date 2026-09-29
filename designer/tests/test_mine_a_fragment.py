import json
import os
from pathlib import Path

import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT

INDEX_PATH = PROJECT_ROOT / "world_index.json"
WORLDS = Path("mines") / "resources" / "worlds"
SIBLING_GAME_DIR = Path(__file__).resolve().parents[3] / "riftal-game"


def _fragment(name: str) -> dict:
    """RiftalMines' fragment for ``name``, from RIFTAL_GAME_DIR or the sibling checkout.

    Same rule as the lumber fragment: only an absent default sibling skips, since CI has no
    riftal-game checkout (riftal-infra#321). An explicit RIFTAL_GAME_DIR lacking the file fails.
    """
    explicit = os.environ.get("RIFTAL_GAME_DIR")
    if explicit:
        path = Path(explicit) / WORLDS / f"{name}.json"
        assert path.is_file(), f"RIFTAL_GAME_DIR is set but {path} does not exist"
    else:
        path = SIBLING_GAME_DIR / WORLDS / f"{name}.json"
        if not path.is_file():
            pytest.skip(f"no riftal-game checkout at {SIBLING_GAME_DIR}; set RIFTAL_GAME_DIR")
    return json.loads(path.read_text(encoding="utf-8"))


def _mine_reset(name: str) -> dict:
    spec = MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / f"{name}.json").read_text(encoding="utf-8")))
    return build_mine(spec, Palette.load("mine_stone")).extras["mine_reset"]


# mine_c's fragment names lapis by the item alias lapis_lazuli_ore, which DesignBridge reads back as
# lapis_ore, so the spec cannot match it until the fragment takes the Bedrock name.
@pytest.mark.parametrize("name", ["mine_a", "mine_b"])
def test_mine_fragment_matches_what_build_mine_computes(name: str) -> None:
    fragment = _fragment(name)
    mine_reset = _mine_reset(name)
    # RiftalMines reads only "ores", so a layer here would vanish at the first reset.
    assert mine_reset.pop("ore_layers") == []
    assert "interior" in fragment
    assert {key: value for key, value in fragment.items() if key != "rank"} == mine_reset


@pytest.mark.parametrize("name", ["mine_a", "mine_b", "mine_c"])
def test_mine_fragment_rank_matches_the_world_index(name: str) -> None:
    fragment = _fragment(name)
    worlds = json.loads(INDEX_PATH.read_text(encoding="utf-8"))["worlds"]
    assert fragment["rank"] == next(w["rank"] for w in worlds if w["name"] == name)
