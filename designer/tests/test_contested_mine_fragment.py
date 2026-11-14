import json
import os
from pathlib import Path

import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT, SIBLING_GAME_DIR

SPEC_PATH = PROJECT_ROOT / "specs" / "contested_mine.json"
FRAGMENT = Path("mines") / "resources" / "worlds" / "contested.json"


# MineDefinition::fromFragment in riftal-game rejects a fragment without any of these.
REQUIRED_KEYS = {"interior", "floor_y", "ores"}


def _spec() -> MineSpec:
    return MineSpec.from_dict(json.loads(SPEC_PATH.read_text(encoding="utf-8")))


def _edit_list():
    return build_mine(_spec(), Palette.load("mine_stone"))


def _mine_reset() -> dict:
    return _edit_list().extras["mine_reset"]


def _fragment_path() -> Path:
    """riftal-game's contested fragment, from RIFTAL_GAME_DIR or the sibling checkout.

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
        pytest.skip(f"no contested fragment at {path}; set RIFTAL_GAME_DIR")
    return path


def test_the_fragment_is_outside_the_rank_ladder() -> None:
    assert "rank" not in json.loads(SPEC_PATH.read_text(encoding="utf-8"))


def test_the_fragment_carries_spec_021_values() -> None:
    mine_reset = _mine_reset()
    assert mine_reset["interior"] == {"min": [-18, 4, -18], "max": [17, 14, 17]}
    assert mine_reset["floor_y"] == 4
    assert mine_reset["ores"] == {"minecraft:iron_ore": 1.0, "minecraft:gold_ore": 0.4, "minecraft:diamond_ore": 0.1}
    assert mine_reset["ore_layers"] == []
    assert mine_reset["reset_percent"] == 60


def test_the_spec_pins_the_build_inputs_the_fragment_does_not_carry() -> None:
    spec = _spec()
    assert spec.seed == 20260907
    assert spec.fill == "solid"
    assert spec.lights_every == 4
    assert (spec.exit_path.width, spec.exit_path.length) == (5, 6)


def test_the_mine_is_pvp_ground() -> None:
    regions = {r["name"]: r for r in _edit_list().extras["regions"]}
    assert "safe_zone" not in regions["contested_mine"]["tags"]
    assert regions["contested_mine"]["world"] == "contested"


def test_the_entrance_and_sell_points_sit_where_spec_021_puts_them() -> None:
    extras = _edit_list().extras
    regions = {r["name"]: r for r in extras["regions"]}
    assert regions["contested_mine_entrance"]["min"] == [-2, 4, 18]
    assert regions["contested_mine_entrance"]["max"] == [2, 7, 19]
    locations = {l["name"]: l for l in extras["locations"]}
    assert locations["sell_npc_mine"]["pos"] == [-1, 4, 25]
    assert locations["rankup_npc_mine"]["pos"] == [1, 4, 25]
    assert locations["contested_mine_exit"]["pos"][2] == 20


def test_riftal_game_fragment_matches_what_build_mine_computes() -> None:
    fragment = json.loads(_fragment_path().read_text(encoding="utf-8"))
    mine_reset = _mine_reset()
    assert "rank" not in fragment
    missing = REQUIRED_KEYS - fragment.keys()
    assert not missing, f"fragment lacks keys MineDefinition requires: {sorted(missing)}"
    unknown = fragment.keys() - mine_reset.keys()
    assert not unknown, f"fragment carries keys build_mine does not compute: {sorted(unknown)}"
    assert {key: mine_reset[key] for key in fragment} == fragment
