"""Spec 005 criteria 2 and 7 on the committed specs: each rank's exclusive material, and a tool ladder with no gap.

Every block a zone holds must drop for a pickaxe crafted from what the zones below it drop, the lumber yard
first. Tiers and drops are pmmp-core's ``src/block/VanillaBlocksInputs.php``: logs take no tool (722), stone a
wooden pickaxe (384), coal a wooden one and copper, iron and lapis a stone one (905-911). No pickaxe past stone
crafts without a furnace (riftal-pm#735), so the drops of copper, iron and lapis raise nothing.
"""

import json

import pytest

from designer.config import PROJECT_ROOT

LADDER = ("lumber", "mine_a", "mine_b", "mine_c")
HAND, WOOD, STONE = 0, 1, 2
NEEDS = {
    "minecraft:oak_log": (HAND, "oak_log"),
    "minecraft:stone": (WOOD, "cobblestone"),
    "minecraft:coal_ore": (WOOD, "coal"),
    "minecraft:copper_ore": (STONE, "raw_copper"),
    "minecraft:iron_ore": (STONE, "raw_iron"),
    "minecraft:lapis_ore": (STONE, "lapis_lazuli"),
}
CRAFTS = {"oak_log": WOOD, "cobblestone": STONE}


def _ores(name: str) -> set[str]:
    return set(json.loads((PROJECT_ROOT / "specs" / f"{name}.json").read_text(encoding="utf-8"))["ores"])


def unbreakable(ladder: dict[str, set[str]]) -> list[str]:
    """``zone block`` for each block no pickaxe crafted from the lower zones' drops can break."""
    out, best = [], HAND
    for zone, ores in ladder.items():
        out += [f"{zone} {block}" for block in sorted(ores) if NEEDS[block][0] > best]
        best = max([best, *(CRAFTS.get(NEEDS[block][1], HAND) for block in ores)])
    return out


def test_every_committed_block_has_a_known_tier() -> None:
    assert [f"{z} {b}" for z in LADDER for b in sorted(_ores(z)) if b not in NEEDS] == []


def test_each_zone_breaks_with_a_pickaxe_from_the_drops_below_it() -> None:
    assert unbreakable({zone: _ores(zone) for zone in LADDER}) == []


def test_a_mine_a_without_stone_leaves_mine_b_unbreakable() -> None:
    ladder = {zone: _ores(zone) for zone in LADDER}
    ladder["mine_a"] -= {"minecraft:stone"}
    assert unbreakable(ladder) == ["mine_b minecraft:copper_ore", "mine_b minecraft:iron_ore", "mine_c minecraft:iron_ore", "mine_c minecraft:lapis_ore"]


@pytest.mark.parametrize("mine", ["mine_a", "mine_b", "mine_c"])
def test_each_mine_carries_a_material_neither_other_mine_does(mine: str) -> None:
    others = set().union(*(_ores(m) for m in ("mine_a", "mine_b", "mine_c") if m != mine))
    assert _ores(mine) - others
