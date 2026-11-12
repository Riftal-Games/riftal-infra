"""The state RiftalMines' reset writes for each ore base a mine spec or fragment names.

The reset places the block of ``MineBlock::resolve(name)`` (riftal-game
``mines/src/RiftalGames/Mines/MineBlock.php``), which reads the name as a Bedrock block id first, so
``minecraft:wheat`` is the wheat crop, and falls back to ``StringToItemParser::parse``. Each entry is the
state that block reads back with, not what the bridge reads back for a bare id (riftal-game#256). A crop
is written at its own max age, ``growth=7`` for all six (riftal-game ``MineResetListener.php``,
``setAge(getMaxAge())``); a stem also reads back ``facing_direction=0``, the one state the bridge refuses
to write without. A crop mine stands its crop row on farmland, which ``build_mine`` writes under it as the
refill does (``MineRefillTask.php``). An entry for a block with states needs a one-time live check on the
designer stack (DECISIONS.md, 2026-09-30).
"""

from __future__ import annotations

from types import MappingProxyType

RESET_STATES = MappingProxyType({
    "minecraft:stone": {},
    "minecraft:cobblestone": {},
    "minecraft:andesite": {},
    "minecraft:coal_ore": {},
    "minecraft:iron_ore": {},
    "minecraft:copper_ore": {},
    "minecraft:gold_ore": {},
    "minecraft:redstone_ore": {},
    "minecraft:lapis_ore": {},
    "minecraft:diamond_ore": {},
    "minecraft:emerald_ore": {},
    "minecraft:oak_log": {"pillar_axis": "y"},
    "minecraft:wheat": {"growth": "7"},
    "minecraft:carrots": {"growth": "7"},
    "minecraft:potatoes": {"growth": "7"},
    "minecraft:beetroot": {"growth": "7"},
    "minecraft:melon_stem": {"facing_direction": "0", "growth": "7"},
    "minecraft:pumpkin_stem": {"facing_direction": "0", "growth": "7"},
})
