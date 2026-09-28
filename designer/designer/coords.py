"""Block coordinates read from JSON-shaped input."""

from __future__ import annotations

import numbers
from collections.abc import Iterable
from typing import Any


def int_coords(values: Iterable[Any], what: str) -> tuple[int, ...]:
    """``values`` as block coordinates, raising ``ValueError(f"{what}, got ...")`` on any that is not a whole number.

    A coordinate names a block, so a fraction is a mistake to report, not a value to round.
    ``4.0`` is accepted; ``True``, ``-0.5``, NaN, infinity and ``"4"`` are not.
    """
    values = tuple(values)
    for v in values:
        whole = isinstance(v, numbers.Integral) or (isinstance(v, numbers.Real) and float(v).is_integer())
        if isinstance(v, bool) or not whole:
            raise ValueError(f"{what}, got {values!r}")
    return tuple(int(v) for v in values)
