"""Builders: pure functions from a spec to an ``EditList``. Holds ``mine_spec``, the mine spec and geometry ``mine_valid`` reads."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from designer.builders.base import Palette
from designer.edits import EditList

# Kind name to the builder that turns its spec dict into an ``EditList``. Each
# builder issue adds its own entry; nothing names ``mine`` here yet.
BUILDERS: dict[str, Callable[[Any, Palette], EditList]] = {}
