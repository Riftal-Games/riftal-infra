"""The state RiftalMines' reset writes for each ore base a mine spec or fragment names.

The reset places the block of ``StringToItemParser::parse(name)`` (riftal-game
``mines/src/RiftalGames/Mines/MineResetListener.php``), so each entry is that item's block's own
state, not what the bridge reads back for a bare id (riftal-game#256). An entry for a block with
states needs a one-time live check on the designer stack (DECISIONS.md, 2026-09-30).
"""

from __future__ import annotations

from types import MappingProxyType

RESET_STATES = MappingProxyType({
    "minecraft:stone": {},
    "minecraft:coal_ore": {},
    "minecraft:iron_ore": {},
    "minecraft:copper_ore": {},
    "minecraft:gold_ore": {},
    "minecraft:redstone_ore": {},
    "minecraft:lapis_ore": {},
    "minecraft:diamond_ore": {},
    "minecraft:emerald_ore": {},
    "minecraft:oak_log": {"pillar_axis": "y"},
})
