"""The map's named things: worlds, locations and regions, kept in ``world_index.json``."""

from __future__ import annotations

import difflib
import json
import re
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from designer.config import PROJECT_ROOT
from designer.region import Bounds

VERSION = 1
NAME_RE = re.compile(r"^[a-z0-9_]+$")
DEFAULT_PATH = PROJECT_ROOT / "world_index.json"
KINDS = ("worlds", "locations", "regions")

Pos = tuple[int, int, int]


def _pos(value: Sequence[int]) -> Pos:
    if len(value) != 3:
        raise ValueError(f"a position is three integers, got {tuple(value)!r}")
    x, y, z = (int(v) for v in value)
    return x, y, z


@dataclass
class Location:
    """A named point. ``pos`` is the feet block in integer block coordinates; ``yaw`` and ``pitch`` are degrees."""

    name: str
    world: str
    pos: Pos
    yaw: float = 0
    pitch: float = 0
    tags: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.pos = _pos(self.pos)

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> Location:
        return cls(data["name"], data["world"], data["pos"], data.get("yaw", 0), data.get("pitch", 0), list(data.get("tags", [])))

    def to_json(self) -> dict[str, Any]:
        return {"name": self.name, "world": self.world, "pos": list(self.pos), "yaw": self.yaw, "pitch": self.pitch, "tags": list(self.tags)}


@dataclass
class NamedRegion:
    name: str
    world: str
    min: Pos
    max: Pos
    tags: list[str] = field(default_factory=list)
    meta: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        box = Bounds(_pos(self.min), _pos(self.max))
        self.min, self.max = box.min, box.max

    @property
    def bounds(self) -> Bounds:
        return Bounds(self.min, self.max)

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> NamedRegion:
        return cls(data["name"], data["world"], data["min"], data["max"], list(data.get("tags", [])), dict(data.get("meta", {})))

    def to_json(self) -> dict[str, Any]:
        return {"name": self.name, "world": self.world, **self.bounds.to_json(), "tags": list(self.tags), "meta": dict(self.meta)}


@dataclass
class WorldEntry:
    """A world the map defines. Keys beyond the fixed four, such as ``rank``, live in ``extra``."""

    name: str
    generator: str
    seed: int
    role: str
    extra: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> WorldEntry:
        extra = {k: v for k, v in data.items() if k not in ("name", "generator", "seed", "role")}
        return cls(data["name"], data["generator"], int(data["seed"]), data["role"], extra)

    def to_json(self) -> dict[str, Any]:
        return {**self.extra, "name": self.name, "generator": self.generator, "seed": self.seed, "role": self.role}


def _missing(kind: str, name: str, known: Sequence[str]) -> KeyError:
    near = difflib.get_close_matches(name, known, n=1)
    hint = f", did you mean {near[0]!r}?" if near else ""
    return KeyError(f"no such {kind} {name!r}{hint}")


@dataclass
class WorldIndex:
    version: int = VERSION
    updated: str = ""
    default_world: str = "design"
    worlds: list[WorldEntry] = field(default_factory=list)
    locations: list[Location] = field(default_factory=list)
    regions: list[NamedRegion] = field(default_factory=list)

    @classmethod
    def load(cls, path: Path | None = None) -> WorldIndex:
        path = DEFAULT_PATH if path is None else Path(path)
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("version") != VERSION:
            raise ValueError(f"{path} is version {data.get('version')!r}; this toolkit reads version {VERSION}")
        lists = {kind: [t.from_json(e) for e in data.get(kind, [])] for kind, t in zip(KINDS, (WorldEntry, Location, NamedRegion))}
        index = cls(VERSION, data.get("updated", ""), data.get("default_world", ""), **lists)
        index.validate()
        return index

    def validate(self) -> None:
        """Raise ``ValueError`` naming the first entry that breaks an invariant ``add_*`` keeps."""
        worlds = {w.name for w in self.worlds}
        if self.default_world not in worlds:
            raise ValueError(f"default_world {self.default_world!r} is not a listed world")
        seen: dict[str, str] = {}
        for entry in (*self.locations, *self.regions):
            what = f"{type(entry).__name__} {entry.name!r}"
            if not NAME_RE.fullmatch(entry.name):
                raise ValueError(f"{what} must match {NAME_RE.pattern}")
            if entry.world not in worlds:
                raise ValueError(f"{what} is in unlisted world {entry.world!r}")
            if entry.name in seen:
                raise ValueError(f"{what} duplicates {seen[entry.name]}")
            seen[entry.name] = what

    def to_json(self) -> dict[str, Any]:
        lists = {kind: [e.to_json() for e in sorted(getattr(self, kind), key=lambda e: e.name)] for kind in KINDS}
        return {"version": self.version, "updated": self.updated, "default_world": self.default_world, **lists}

    def save(self, path: Path | None = None, *, updated: str | None = None) -> Path:
        """Write the index; ``updated`` defaults to now, and is the only field that changes on a re-save."""
        path = DEFAULT_PATH if path is None else Path(path)
        self.updated = datetime.now(UTC).isoformat(timespec="seconds") if updated is None else updated
        path.write_text(json.dumps(self.to_json(), indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
        return path

    def names(self) -> dict[str, Location | NamedRegion]:
        return {e.name: e for e in (*self.locations, *self.regions)}

    def world(self, name: str) -> WorldEntry:
        for entry in self.worlds:
            if entry.name == name:
                return entry
        raise _missing("world", name, [w.name for w in self.worlds])

    def resolve(self, name: str) -> Location | NamedRegion:
        named = self.names()
        if name not in named:
            raise _missing("name", name, list(named))
        return named[name]

    def resolve_pos(self, ref: str | Sequence[int]) -> tuple[int, int | None, int]:
        """``(x, y, z)`` of a location, a region's centre block, an ``x,y,z`` string or a 3-list; ``x,z`` gives ``y=None``.

        The centre of an even-sized region is the upper of its two middle blocks, so ``Bounds.from_center`` gives the region back.
        """
        if not isinstance(ref, str):
            return _pos(ref)
        if "," not in ref:
            entry = self.resolve(ref)
            return entry.pos if isinstance(entry, Location) else _pos([lo + (hi - lo + 1) // 2 for lo, hi in zip(entry.min, entry.max)])
        parts = [int(p) for p in ref.split(",")]
        return (parts[0], None, parts[1]) if len(parts) == 2 else _pos(parts)

    def locations_tagged(self, tag: str) -> list[Location]:
        return [l for l in self.locations if tag in l.tags]

    def regions_tagged(self, tag: str) -> list[NamedRegion]:
        return [r for r in self.regions if tag in r.tags]

    def _add(self, entry: Any, into: list[Any], replace: bool) -> Any:
        if not NAME_RE.fullmatch(entry.name):
            raise ValueError(f"name {entry.name!r} must match {NAME_RE.pattern}")
        self.world(entry.world)
        if entry.name in self.names():
            if not replace:
                raise ValueError(f"{entry.name!r} is already defined; pass replace=True to overwrite it")
            self.remove(entry.name)
        into.append(entry)
        return entry

    def add_location(self, location: Location, *, replace: bool = False) -> Location:
        return self._add(location, self.locations, replace)

    def add_region(self, region: NamedRegion, *, replace: bool = False) -> NamedRegion:
        return self._add(region, self.regions, replace)

    def remove(self, name: str) -> Location | NamedRegion:
        entry = self.resolve(name)
        (self.locations if isinstance(entry, Location) else self.regions).remove(entry)
        return entry
