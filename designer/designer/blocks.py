"""Block names, block classes and the region run-length encoding."""

from __future__ import annotations

import logging
from collections.abc import Callable, Mapping, Sequence
from enum import IntEnum
from typing import Any

import numpy as np

log = logging.getLogger("designer.blocks")

AIR = "minecraft:air"
NAMESPACE = "minecraft:"

# Wire order of a region's runs and axis order of every decoded array,
# outermost first: ``blocks[y][z][x]``, x varies fastest.
RLE_ORDER = ("y", "z", "x")
ARRAY_AXES = ("y", "z", "x")


class BlockClass(IntEnum):
    AIR = 0
    SOLID = 1
    LIQUID = 2
    PASSABLE = 3
    DANGER = 4


class RLEError(ValueError):
    """A region payload does not describe the bounds it claims."""


def parse_name(name: str) -> tuple[str, dict[str, str]]:
    """Split ``minecraft:oak_log[pillar_axis=y]`` into its namespaced base and states."""
    base, bracket, rest = name.strip().partition("[")
    base = base.strip()
    if not base:
        raise ValueError(f"block name has no base: {name!r}")
    if ":" not in base:
        base = NAMESPACE + base
    states: dict[str, str] = {}
    if bracket:
        if not rest.endswith("]"):
            raise ValueError(f"unterminated block states: {name!r}")
        body = rest[:-1].strip()
        for item in body.split(",") if body else ():
            key, eq, value = item.partition("=")
            if not eq or not key.strip():
                raise ValueError(f"malformed block state {item!r} in {name!r}")
            states[key.strip()] = value.strip()
    return base, states


def format_name(base: str, states: Mapping[str, Any] | None = None) -> str:
    """Canonical name: namespaced base, states sorted by key, booleans lowercase."""
    if ":" not in base:
        base = NAMESPACE + base
    if not states:
        return base
    parts = (f"{k}={str(v).lower() if isinstance(v, bool) else str(v)}" for k, v in sorted(states.items()))
    return f"{base}[{','.join(parts)}]"


def base_name(name: str) -> str:
    """The name with namespace and states stripped: ``oak_log``."""
    return parse_name(name)[0].rpartition(":")[2]


RULE_KINDS = ("exact", "prefix", "suffix", "contains")

StateClass = Callable[[Mapping[str, str]], BlockClass]

# A PASSABLE feet cell promises a 1.8-tall hitbox (Human.php:121) fits under a
# ceiling two cells up, which leaves this much of a block for a box beneath
# it. A taller box clips the ceiling, the same headroom rule that makes a 3/8
# flower pot SOLID. It is below the 0.6 step-up (Player.php:281), so it holds
# for climbing too.
FEET_CELL_HEADROOM = 2 - 1.8


def _by_box_top(top: float) -> BlockClass:
    return BlockClass.SOLID if top > FEET_CELL_HEADROOM else BlockClass.PASSABLE


class _MalformedState(ValueError):
    """A state a rule reads does not hold the type the rule needs."""


def _int_state(states: Mapping[str, str], key: str) -> int:
    try:
        return int(states.get(key, "0"))
    except ValueError:
        raise _MalformedState(f"{key}={states[key]!r}") from None


# Bedrock's ``height`` is layers minus one and the collision box is ``height``
# eighths of a block (SnowLayer.php:69), so from height 2 (0.25) it is SOLID.
def _snow_layer(states: Mapping[str, str]) -> BlockClass:
    return _by_box_top(_int_state(states, "height") / 8)


# ``growth`` 0-2 is the one-block crop, 3/16 tall at 0 and 5/16 after
# (PitcherCrop.php:54). From 3 it is the double crop, whose lower half is 5/16
# (DoublePitcherCrop.php:61) and upper half has no box (:54).
def _pitcher_crop(states: Mapping[str, str]) -> BlockClass:
    if states.get("upper_block_bit") == "true":
        return BlockClass.PASSABLE
    growth = _int_state(states, "growth")
    return _by_box_top((3 if growth == 0 else 5) / 16)


# First match wins, on the base name. A seeded rule whose class is a function
# decides from the block's states, for a block whose collision a state
# changes. ``register_rule(front=True)`` inserts at index 0 to beat every
# seeded rule.
CLASS_RULES: list[tuple[str, str, BlockClass | StateClass]] = [
    *(("exact", n, BlockClass.AIR) for n in ("air", "cave_air", "void_air")),
    *(("exact", n, BlockClass.LIQUID) for n in ("water", "flowing_water", "bubble_column")),
    *(("exact", n, BlockClass.DANGER) for n in (
        "lava", "flowing_lava", "fire", "soul_fire", "magma", "cactus",
        "sweet_berry_bush", "wither_rose", "powder_snow", "campfire", "soul_campfire")),
    # No collision box, and a player who enters it leaves the world at once.
    # The core does not implement it, so this follows vanilla Bedrock.
    ("exact", "end_portal", BlockClass.DANGER),
    ("exact", "snow_layer", _snow_layer),
    ("exact", "pitcher_crop", _pitcher_crop),
    *(("exact", n, BlockClass.PASSABLE) for n in (
        "lever", "ladder", "vine", "fern", "large_fern", "dead_bush",
        "redstone_wire", "lily_pad", "waterlily", "kelp", "seagrass",
        "sugar_cane", "reeds", "bamboo_sapling", "hanging_roots", "dandelion", "poppy", "blue_orchid",
        "allium", "azure_bluet", "oxeye_daisy", "cornflower", "lily_of_the_valley",
        "sunflower", "lilac", "rose_bush", "peony", "pitcher_plant",
        "double_plant", "red_flower", "yellow_flower",
        "wheat", "carrots", "potatoes", "beetroot", "melon_stem", "pumpkin_stem",
        "nether_wart", "web", "cobweb", "trip_wire", "deadbush", "structure_void", "glow_lichen",
        "resin_clump", "spore_blossom", "red_mushroom", "brown_mushroom", "crimson_roots",
        "warped_roots", "nether_sprouts", "pink_petals", "frame", "glow_frame", "portal",
        "mangrove_propagule", "open_eyeblossom", "closed_eyeblossom", "wildflowers",
        "leaf_litter")),
    ("prefix", "tripwire", BlockClass.PASSABLE),
    ("prefix", "cave_vines", BlockClass.PASSABLE),
    ("prefix", "light_block", BlockClass.PASSABLE),
    ("prefix", "small_dripleaf", BlockClass.PASSABLE),
    # A full-collision block the "flower" suffix below would otherwise take.
    ("exact", "chorus_flower", BlockClass.SOLID),
    *(("suffix", s, BlockClass.PASSABLE) for s in (
        "sign", "button", "pressure_plate", "rail", "carpet", "sapling", "flower",
        "tulip", "banner", "fungus", "_vines", "_grass", "_coral", "_coral_fan", "_coral_wall_fan")),
    ("contains", "torch", BlockClass.PASSABLE),
]


def register_rule(kind: str, pattern: str, cls: BlockClass, front: bool = True) -> None:
    """Add a rule. ``front`` rules override every existing one for their match."""
    if kind not in RULE_KINDS:
        raise ValueError(f"unknown rule kind {kind!r}, expected one of {RULE_KINDS}")
    rule = (kind, pattern, BlockClass(cls))
    if front:
        CLASS_RULES.insert(0, rule)
    else:
        CLASS_RULES.append(rule)


def _matches(kind: str, pattern: str, base: str) -> bool:
    if kind == "exact":
        return base == pattern
    if kind == "prefix":
        return base.startswith(pattern)
    if kind == "suffix":
        return base.endswith(pattern)
    return pattern in base


def _classify(name: str) -> BlockClass:
    base, states = parse_name(name)
    base = base.rpartition(":")[2]
    for kind, pattern, cls in CLASS_RULES:
        if _matches(kind, pattern, base):
            return cls(states) if callable(cls) else cls
    return BlockClass.SOLID


# A malformed state says nothing about the box, so the block is SOLID, the
# class given to any block that cannot be read, rather than one bad palette
# entry failing ``class_lut`` for the whole region.
def classify(name: str) -> BlockClass:
    try:
        return _classify(name)
    except _MalformedState:
        return BlockClass.SOLID


def class_lut(palette: Sequence[str]) -> np.ndarray:
    """Palette index to ``BlockClass``, for ``lut[blocks]`` over a whole region.

    Warns once per distinct palette entry with a malformed state, since a
    bridge sending bad state values would otherwise change classes unnoticed.
    """
    classes: list[BlockClass] = []
    malformed: dict[str, _MalformedState] = {}
    for name in palette:
        try:
            classes.append(_classify(name))
        except _MalformedState as err:
            classes.append(BlockClass.SOLID)
            malformed.setdefault(name, err)
    for name, err in malformed.items():
        log.warning("block %r has malformed state %s, classified SOLID", name, err)
    return np.array(classes, dtype=np.uint8)


def _axes_from(order: Sequence[str], to: Sequence[str]) -> list[int]:
    if sorted(order) != sorted(ARRAY_AXES) or len(order) != 3:
        raise ValueError(f"order must be a permutation of {ARRAY_AXES}, got {tuple(order)!r}")
    return [list(order).index(axis) for axis in to]


def expand_runs(payload: Mapping[str, Any], *, order: Sequence[str] = RLE_ORDER) -> tuple[np.ndarray, list[Any]]:
    """Expand a payload's runs into palette indices ``[y][z][x]``; the palette is returned as sent."""
    claimed = payload.get("order")
    if claimed is not None and tuple(claimed) != tuple(order):
        raise RLEError(f"payload order {claimed!r} does not match expected {''.join(order)!r}")
    lo, hi = payload["min"], payload["max"]
    size = {axis: hi[i] - lo[i] + 1 for i, axis in enumerate("xyz")}
    if min(size.values()) < 1:
        raise RLEError(f"empty bounds min={lo} max={hi}")
    volume = size["x"] * size["y"] * size["z"]

    palette = list(payload["palette"])
    runs = np.asarray(payload["runs"], dtype=np.int64).reshape(-1, 2)
    indices, counts = runs[:, 0], runs[:, 1]
    total = int(counts.sum())
    if total != volume:
        raise RLEError(f"runs cover {total} blocks, bounds hold {volume}")
    if len(indices) and (indices.min() < 0 or indices.max() >= len(palette)):
        raise RLEError(f"run index outside palette of {len(palette)}")
    if len(counts) and counts.min() < 1:
        raise RLEError(f"run count below 1: {int(counts.min())}")

    flat = np.repeat(indices, counts)
    return flat.reshape([size[axis] for axis in order]).transpose(_axes_from(order, ARRAY_AXES)), palette


def decode_rle(
    payload: Mapping[str, Any], *, order: Sequence[str] = RLE_ORDER
) -> tuple[np.ndarray, list[str]]:
    """Expand a region payload into ``blocks[y][z][x]`` int16 with air at palette index 0."""
    blocks, palette = expand_runs(payload, order=order)
    if AIR not in palette:
        palette.insert(0, AIR)
        blocks = blocks + 1
    elif (k := palette.index(AIR)) != 0:
        palette[0], palette[k] = palette[k], palette[0]
        lut = np.arange(len(palette))
        lut[0], lut[k] = k, 0
        blocks = lut[blocks]
    return np.ascontiguousarray(blocks, dtype=np.int16), palette


def encode_rle(
    blocks: np.ndarray, palette: Sequence[str], *,
    order: Sequence[str] = RLE_ORDER, origin: Sequence[int] = (0, 0, 0),
) -> dict[str, Any]:
    """Pack ``blocks[y][z][x]`` into a region payload whose bounds start at ``origin``."""
    if blocks.ndim != 3:
        raise ValueError(f"blocks must be [y][z][x], got {blocks.ndim} dimensions")
    flat = blocks.transpose(_axes_from(ARRAY_AXES, order)).ravel()
    if flat.size and (flat.min() < 0 or flat.max() >= len(palette)):
        raise ValueError(f"block index outside palette of {len(palette)}")

    starts = np.flatnonzero(flat[1:] != flat[:-1]) + 1
    starts = np.concatenate(([0], starts)) if flat.size else starts
    ends = np.concatenate((starts[1:], [flat.size]))
    runs = np.stack((flat[starts], ends - starts), axis=1).tolist()

    ny, nz, nx = blocks.shape
    ox, oy, oz = (int(v) for v in origin)
    return {
        "min": [ox, oy, oz],
        "max": [ox + nx - 1, oy + ny - 1, oz + nz - 1],
        "order": "".join(order),
        "palette": list(palette),
        "runs": runs,
        "volume": int(flat.size),
    }
