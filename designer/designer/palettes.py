"""The committed ``palettes.json``: render colours and the role palettes builders draw from."""

from __future__ import annotations

import json
from functools import cache
from pathlib import Path
from typing import Any

PALETTES_FILE = Path(__file__).with_name("palettes.json")

# Every named palette must bind each of these, because builders ask for roles
# and never for block names.
ROLES = (
    "wall", "wall_trim", "floor", "ceiling", "road", "road_edge", "stairs",
    "slab", "light", "boundary", "boundary_accent", "plot_edge", "plot_floor", "sign",
)

# The roles a ``hall`` step draws from. A palette binds either these or ``ROLES``, never a mix, so the hall's
# look is its own palette and a mine's shell palette stays as it is.
HALL_ROLES = (
    "hall_wall", "hall_floor_a", "hall_floor_b", "hall_ceiling", "pilaster", "gate_jamb", "gate_lintel", "keystone",
    "cornice",
)


@cache
def load_palettes() -> dict[str, Any]:
    data = json.loads(PALETTES_FILE.read_text(encoding="utf-8"))
    for name, rgb in data["colors"].items():
        if len(rgb) != 3 or any(not isinstance(c, int) or not 0 <= c <= 255 for c in rgb):
            raise ValueError(f"colour of {name} must be three ints in 0..255, got {rgb!r}")
    for name, palette in data["palettes"].items():
        wanted = set(HALL_ROLES if name.startswith("hall_") else ROLES)
        if set(palette) != wanted:
            raise ValueError(f"palette {name} roles differ from the spec: {sorted(set(palette) ^ wanted)}")
    return data
