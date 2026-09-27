"""Builders: pure functions from a spec to an ``EditList``. Holds ``mine_spec``, the mine spec and geometry ``mine_valid`` reads."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.edits import EditList

# Kind name to the builder that turns its spec dict into an ``EditList``. A
# builder's own function typically wants its dataclass, not the raw dict, so
# the entry here is the thing that closes over that conversion. Each builder
# issue adds its own entry.
BUILDERS: dict[str, Callable[[dict[str, Any], Palette], EditList]] = {
    "mine": lambda spec, palette: build_mine(MineSpec.from_dict(spec), palette),
}
