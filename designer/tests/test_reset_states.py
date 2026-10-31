import json
import os
from pathlib import Path

import pytest

from designer.blocks import format_name
from designer.builders import BUILDERS
from designer.builders.base import Palette
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


@pytest.mark.parametrize("ores", [
    {f"{LOG}[pillar_axis=y]": 1.0, f"{LOG}[pillar_axis=x]": 0.5},
    {f"{LOG}[pillar_axis=x]": 1.0},
    {"minecraft:stone": 1.0, "riftal:stone": 0.5},
])
def test_from_dict_refuses_an_ores_key_the_reset_cannot_resolve(ores: dict[str, float]) -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    with pytest.raises(ValueError, match="which the mine reset cannot resolve"):
        MineSpec.from_dict({**data, "ores": ores})


def test_from_dict_refuses_an_ore_layer_key_the_reset_cannot_resolve() -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    layer = {"y_from": data["floor_y"], "y_to": data["floor_y"], "ores": {f"{LOG}[pillar_axis=y]": 1.0}}
    with pytest.raises(ValueError, match="ore_layers names .*which the mine reset cannot resolve"):
        MineSpec.from_dict({**data, "ore_layers": [layer]})


@pytest.mark.parametrize(("field", "value"), [
    ("ores", {"minecraft:wheat[growth=0]": 1.0}),
    ("ore_layers", [{"y_from": 40, "y_to": 40, "ores": {"minecraft:coal_ore[lit=true]": 1.0}}]),
])
def test_the_mine_builder_refuses_a_stated_ore_key_instead_of_writing_it_to_mine_reset(field: str, value: object) -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    with pytest.raises(ValueError, match="which the mine reset cannot resolve"):
        BUILDERS["mine"]({**data, field: value}, Palette.load("mine_stone"), lambda *_: None)


def test_the_mine_builder_writes_only_bare_ids_to_mine_reset() -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    layer = {"y_from": data["floor_y"], "y_to": data["floor_y"], "ores": {"coal_ore": 1.0}}
    fragment = BUILDERS["mine"]({**data, "ore_layers": [layer]}, Palette.load("mine_stone"), lambda *_: None).extras["mine_reset"]
    keys = [*fragment["ores"], *(k for l in fragment["ore_layers"] for k in l["ores"])]
    assert keys and all("[" not in k for k in keys) and "minecraft:coal_ore" in fragment["ore_layers"][0]["ores"]


def test_from_dict_accepts_a_bare_id_with_or_without_its_namespace() -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    assert MineSpec.from_dict({**data, "ores": {"oak_log": 1.0, "minecraft:stone": 0.5}}).ores == {LOG: 1.0, "minecraft:stone": 0.5}


def test_from_dict_refuses_an_ores_key_spelling_the_not_reset_marker() -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    ores = {"minecraft:quartz_ore": 1.0, "minecraft:quartz_ore (not its reset state)": 99.0}
    with pytest.raises(ValueError, match="which is not a block id"):
        MineSpec.from_dict({**data, "ores": ores})


CROPS = {
    "minecraft:wheat": "minecraft:wheat[growth=7]",
    "minecraft:carrots": "minecraft:carrots[growth=7]",
    "minecraft:potatoes": "minecraft:potatoes[growth=7]",
    "minecraft:beetroot": "minecraft:beetroot[growth=7]",
    "minecraft:melon_stem": "minecraft:melon_stem[facing_direction=0,growth=7]",
    "minecraft:pumpkin_stem": "minecraft:pumpkin_stem[facing_direction=0,growth=7]",
}


@pytest.mark.parametrize(("base", "read_back"), CROPS.items())
def test_a_crop_reset_state_is_its_live_max_age_read_back(base: str, read_back: str) -> None:
    assert format_name(base, RESET_STATES[base]) == read_back


@pytest.mark.parametrize(("base", "read_back"), CROPS.items())
def test_a_crop_matches_its_key_only_at_max_age(base: str, read_back: str) -> None:
    young = read_back.replace("growth=7", "growth=0")
    assert _as_ores([read_back, young], {base: 1.0}) == [base, young]
