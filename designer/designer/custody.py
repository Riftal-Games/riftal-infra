"""ADR 013 item 4 over ``scan_items`` findings: the saved entities a server loading ``custody`` destroys on chunk load.

The designer stack does not load ``custody``, so such an entity survives every design session and is
destroyed on the first load that has it. Pure, no server.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Iterable
from typing import Any

from designer.verify import Check, Pos

# Every save name core registers for the item-yielding classes of ADR 013 item 1
# (pmmp-core src/entity/EntityFactory.php:91-210), and each one's legacy int id from
# bedrock-data's entity_id_map.json, which core reads masked to its low byte.
OFF_DISK = frozenset({
    "Item", "minecraft:item", "Arrow", "minecraft:arrow", "FallingSand", "minecraft:falling_block",
    "Painting", "minecraft:painting", "minecraft:trident", "minecraft:thrown_trident", "Trident", "ThrownTrident",
})
OFF_DISK_LEGACY = frozenset({64, 66, 73, 80, 83})

# Every other class core registers (EntityFactory.php:91-210) except Human. None is in ADR 013 item 1's off-disk
# set, so a saved one stays.
NO_ITEM = frozenset({
    "AreaEffectCloud", "minecraft:area_effect_cloud", "Egg", "minecraft:egg", "EnderCrystal", "minecraft:ender_crystal",
    "ThrownEnderpearl", "minecraft:ender_pearl", "ThrownExpBottle", "minecraft:xp_bottle", "XPOrb", "minecraft:xp_orb",
    "minecraft:ice_bomb", "PrimedTnt", "PrimedTNT", "minecraft:tnt", "Snowball", "minecraft:snowball",
    "ThrownPotion", "minecraft:potion", "thrownpotion", "Squid", "minecraft:squid", "Villager", "minecraft:villager",
    "Zombie", "minecraft:zombie",
})

# ``scan_items`` reports a saved entity's id and position only, so a saved Human cannot be shown to hold
# nothing, and a save id core does not register may be a plugin's Human subclass. Both fail rather than pass unread.
HUMAN = "Human"

REPORTED = 20


def _legacy(save_id: Any) -> int | None:
    if isinstance(save_id, int) and not isinstance(save_id, bool):
        return save_id & 0xFF
    if isinstance(save_id, str) and save_id.isdigit():
        return int(save_id) & 0xFF
    return None


def classify(save_id: Any) -> str | None:
    """Why item 4 would or might destroy an entity saved under ``save_id``, or ``None`` when it stays."""
    legacy = _legacy(save_id)
    if save_id in OFF_DISK or legacy in OFF_DISK_LEGACY:
        return "yields an item"
    if save_id == HUMAN:
        return "a Human whose inventory, armor and offhand scan_items does not report"
    if save_id in NO_ITEM:
        return None
    return "a save id core does not register"


def offdisk_clear(findings: Iterable[dict[str, Any]]) -> Check:
    """Pass when no saved entity in ``findings`` is one item 4 destroys or one it cannot be ruled out for."""
    entities = [f for f in findings if f.get("kind") == "entity"]
    hits = [(f, why) for f in entities if (why := classify(f.get("save_id"))) is not None]
    if not hits:
        return Check(True, f"{len(entities)} saved entities, none that ADR 013 item 4 destroys on load")
    counts = Counter((str(f.get("save_id")), why) for f, why in hits)
    listed = ", ".join(f"{n} {save_id} ({why})" for (save_id, why), n in sorted(counts.items()))
    coords: list[Pos] = [(int(f["pos"][0]), int(f["pos"][1]), int(f["pos"][2])) for f, _ in hits[:REPORTED]]
    return Check(False, f"{len(hits)} of {len(entities)} saved entities fail ADR 013 item 4: {listed}", coords)
