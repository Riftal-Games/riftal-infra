"""Block coordinates read from JSON-shaped input."""

from __future__ import annotations

import numbers
from collections.abc import Iterable
from typing import Any


def _is_whole(v: Any) -> bool:
    """A coordinate names a block, so a fraction is a mistake to report, not a value to round."""
    if isinstance(v, bool):
        return False
    return isinstance(v, numbers.Integral) or (isinstance(v, numbers.Real) and float(v).is_integer())


def int_coords(values: Iterable[Any], what: str) -> tuple[int, ...]:
    """``values`` as block coordinates, raising ``ValueError(f"{what}, got ...")`` on any that is not a whole number.

    ``4.0`` is accepted; ``True``, ``-0.5``, NaN, infinity and ``"4"`` are not.
    """
    values = tuple(values)
    if not all(_is_whole(v) for v in values):
        raise ValueError(f"{what}, got {values!r}")
    return tuple(int(v) for v in values)


def int_coord(value: Any, what: str) -> int:
    """``value`` as one block coordinate, under the same rule and message shape as ``int_coords``."""
    if not _is_whole(value):
        raise ValueError(f"{what}, got {value!r}")
    return int(value)
