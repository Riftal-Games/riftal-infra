import json
import os
from pathlib import Path

import pytest

from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT
from designer.reset_states import RESET_STATES
from designer.verify import NOT_RESET_STATE, _as_ores

WORLDS = Path("mines") / "resources" / "worlds"
SIBLING_GAME_DIR = Path(__file__).resolve().parents[3] / "riftal-game"
LOG = "minecraft:oak_log"


def _ore_bases(data: dict) -> set[str]:
    names = [*data.get("ores", {}), *(n for layer in data.get("ore_layers") or [] for n in layer["ores"])]
    return {n.split("[", 1)[0] for n in names}


def test_every_committed_spec_ore_has_a_reset_state() -> None:
    bases = set().union(*(_ore_bases(json.loads(p.read_text(encoding="utf-8"))) for p in (PROJECT_ROOT / "specs").glob("*.json")))
    assert bases and sorted(bases - set(RESET_STATES)) == []


def test_every_riftal_game_fragment_ore_has_a_reset_state() -> None:
    explicit = os.environ.get("RIFTAL_GAME_DIR")
    worlds = (Path(explicit) if explicit else SIBLING_GAME_DIR) / WORLDS
    if not explicit and not worlds.is_dir():
        pytest.skip(f"no riftal-game checkout at {SIBLING_GAME_DIR}; set RIFTAL_GAME_DIR")
    fragments = sorted(worlds.glob("*.json"))
    assert fragments, f"no fragments under {worlds}"
    bases = set().union(*(_ore_bases(json.loads(p.read_text(encoding="utf-8"))) for p in fragments))
    assert sorted(bases - set(RESET_STATES)) == []


def test_a_key_matches_only_the_reset_state_of_its_base() -> None:
    palette = [f"{LOG}[pillar_axis=y]", f"{LOG}[pillar_axis=x]", "minecraft:coal_ore", "minecraft:coal_ore[lit=true]"]
    assert _as_ores(palette, {LOG: 1.0, "minecraft:coal_ore": 1.0}) == [
        LOG, f"{LOG}[pillar_axis=x]", "minecraft:coal_ore", "minecraft:coal_ore[lit=true]",
    ]


# Each key below spells the block's whole canonical name, so only a name outside
# the keys proves the block went unmatched.
def test_a_base_without_a_reset_state_matches_nothing() -> None:
    ores = {"minecraft:quartz_ore": 1.0}
    assert _as_ores(["minecraft:quartz_ore"], ores) == [f"minecraft:quartz_ore{NOT_RESET_STATE}"]


def test_a_key_naming_a_non_reset_state_matches_nothing() -> None:
    ores = {f"{LOG}[pillar_axis=x]": 1.0}
    assert _as_ores([f"{LOG}[pillar_axis=x]"], ores) == [f"{LOG}[pillar_axis=x]{NOT_RESET_STATE}"]


@pytest.mark.parametrize("ores", [
    {"minecraft:coal_ore": 1.0, "minecraft:coal_ore[lit=false]": 0.5},
    {f"{LOG}[pillar_axis=y]": 1.0, LOG: 0.5},
])
def test_from_dict_refuses_ores_keys_one_block_can_satisfy_both_of(ores: dict[str, float]) -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    with pytest.raises(ValueError, match="which one block can satisfy both of"):
        MineSpec.from_dict({**data, "ores": ores})


def test_from_dict_accepts_ores_keys_on_disjoint_states_of_one_base() -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    ores = {f"{LOG}[pillar_axis=y]": 1.0, f"{LOG}[pillar_axis=x]": 0.5}
    assert MineSpec.from_dict({**data, "ores": ores}).ores == ores
