"""``build_signage``: floating text markers as an ``EditList``, one ``set_text`` per named sign."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from designer.edits import EditList, Text
from designer.world_index import Location

Triple = tuple[int, int, int]


@dataclass(frozen=True)
class Sign:
    """One floating text marker; ``name`` doubles as its ``set_text`` id and its index location name."""

    name: str
    pos: Triple
    text: str

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> Sign:
        missing = [k for k in ("name", "pos", "text") if k not in data]
        if missing:
            raise ValueError(f"sign is missing {missing}")
        try:
            if len(data["pos"]) != 3:
                raise ValueError("pos must be three integers")
            return cls(str(data["name"]), tuple(int(v) for v in data["pos"]), str(data["text"]))
        except (TypeError, KeyError, IndexError) as e:
            raise ValueError(f"sign is malformed: {e!r}") from e


@dataclass(frozen=True)
class SignageSpec:
    """A batch of ``Sign``s in one ``world``. No name of its own, like ``StairsSpec``: each sign is a named
    place, the batch is not."""

    world: str
    signs: tuple[Sign, ...]

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> SignageSpec:
        missing = [k for k in ("world", "signs") if k not in data]
        if missing:
            raise ValueError(f"signage spec is missing {missing}")
        signs = tuple(Sign.from_dict(s) for s in data["signs"])
        if not signs:
            raise ValueError("signage spec needs at least one sign")
        names = [s.name for s in signs]
        if len(set(names)) != len(names):
            raise ValueError(f"sign names must be unique, got {names}")
        return cls(str(data["world"]), signs)


def build_signage(spec: SignageSpec) -> EditList:
    """One ``Text`` op per sign, and one index location per sign tagged ``sign`` at the same position."""
    ops = [Text(*sign.pos, sign.text, sign.name) for sign in spec.signs]
    locations = [Location(sign.name, spec.world, sign.pos, tags=["sign"]).to_json() for sign in spec.signs]
    return EditList(spec.world, ops, {"locations": locations})
