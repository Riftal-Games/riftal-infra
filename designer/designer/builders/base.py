"""Shared builder infrastructure: palette role lookup, spec-dict helpers, direction and state math."""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Any

from designer.blocks import base_name, format_name, parse_name
from designer.palettes import load_palettes

# Cardinal direction name to its (dx, dz) step.
DIRS: dict[str, tuple[int, int]] = {
    "north": (0, -1),
    "south": (0, 1),
    "east": (1, 0),
    "west": (-1, 0),
}

_OPPOSITES = {"north": "south", "south": "north", "east": "west", "west": "east"}

# The states a shape needs to actually face a direction, per the PR #69 review
# note: a bare role block name only survives the bridge's alias fallback with
# whatever orientation that alias defaults to, so builders append these themselves.
_STAIRS_FACING = {"east": 0, "west": 1, "south": 2, "north": 3}
_SIGN_ROTATION = {"south": 0, "west": 4, "north": 8, "east": 12}


@dataclass(frozen=True)
class Palette:
    """Role name to block string, resolved from a named palette in ``palettes.json``."""

    name: str
    roles: dict[str, str]

    @classmethod
    def load(cls, name: str) -> Palette:
        palettes = load_palettes()["palettes"]
        if name not in palettes:
            raise ValueError(f"unknown palette {name!r}, expected one of {sorted(palettes)}")
        return cls(name, dict(palettes[name]))

    def block(self, role: str) -> str:
        """The block bound to ``role``, or a ``ValueError`` naming the missing role."""
        try:
            return self.roles[role]
        except KeyError:
            raise ValueError(f"palette {self.name!r} has no role {role!r}, expected one of {sorted(self.roles)}") from None


def require(spec: Mapping[str, Any], key: str) -> Any:
    """``spec[key]``, or a ``ValueError`` naming the field a builder spec is missing."""
    try:
        return spec[key]
    except KeyError:
        raise ValueError(f"spec is missing required field {key!r}") from None


def opt(spec: Mapping[str, Any], key: str, default: Any = None) -> Any:
    """``spec[key]`` if present, else ``default``."""
    return spec.get(key, default)


def opposite(direction: str) -> str:
    """The direction that faces the other way: north<->south, east<->west."""
    try:
        return _OPPOSITES[direction]
    except KeyError:
        raise ValueError(f"direction must be one of {sorted(DIRS)}, got {direction!r}") from None


def perpendicular(direction: str) -> tuple[str, str]:
    """The two directions at right angles to ``direction``."""
    if direction not in DIRS:
        raise ValueError(f"direction must be one of {sorted(DIRS)}, got {direction!r}")
    return ("east", "west") if direction in ("north", "south") else ("north", "south")


def facing_state(block: str, direction: str | None = None, *, half: str | None = None, connect: Iterable[str] = ()) -> str:
    """``block`` with the state its shape needs to actually face ``direction``.

    Stairs get ``weirdo_direction``, ``upside_down_bit`` and a straight ``minecraft:corner``, which the core's
    deserializer refuses a stair without; slabs get
    ``top_slot_bit`` from ``half``; walls get a connection per direction in
    ``connect``; signs get ``ground_sign_direction``. Any other block is
    returned with its existing states untouched.
    """
    base, states = parse_name(block)
    name, states = base_name(block), dict(states)
    if name.endswith("_stairs"):
        if direction not in _STAIRS_FACING:
            raise ValueError(f"stairs need a direction in {sorted(_STAIRS_FACING)}, got {direction!r}")
        states["weirdo_direction"] = _STAIRS_FACING[direction]
        states["upside_down_bit"] = half == "top"
        states["minecraft:corner"] = "none"
    elif name.endswith("_slab"):
        if half not in ("top", "bottom"):
            raise ValueError(f"slab needs half='top' or half='bottom', got {half!r}")
        states["top_slot_bit"] = half == "top"
    elif name.endswith("_wall"):
        sides = set(connect)
        if unknown := sides - set(DIRS):
            raise ValueError(f"wall connections must be in {sorted(DIRS)}, got {sorted(unknown)}")
        for d in DIRS:
            states[f"wall_connection_type_{d}"] = "short" if d in sides else "none"
        states["wall_post_bit"] = sides not in ({"north", "south"}, {"east", "west"})
    elif "sign" in name:
        if direction not in _SIGN_ROTATION:
            raise ValueError(f"sign needs a direction in {sorted(_SIGN_ROTATION)}, got {direction!r}")
        states["ground_sign_direction"] = _SIGN_ROTATION[direction]
    return format_name(base, states)
