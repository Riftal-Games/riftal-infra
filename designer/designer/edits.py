"""Edit lists: pure descriptions of block changes; ``apply`` is the one call that sends them."""

from __future__ import annotations

import dataclasses
import json
from collections.abc import Callable
from dataclasses import dataclass, field
from functools import reduce
from itertools import groupby
from typing import Any

from designer.blocks import format_name, parse_name
from designer.bridge import Bridge, BridgeError
from designer.region import MAX_EDGE, Bounds, Region

# The bridge's ``max_set_blocks``; a bigger batch is refused before it is sent.
MAX_SET_BLOCKS = 65536
# The bridge's ``max_line_bytes``: a longer request line is answered BAD_REQUEST and its connection closed.
MAX_LINE_BYTES = 1 << 20
# What a line holds beyond the op's args: the request id, the op name and the token.
# 4096 is room for a token of a few kilobytes.
LINE_BUDGET = MAX_LINE_BYTES - 4096
DEFAULT_BATCH = 4096
COALESCE_RUN = 8


def _wire_bytes(value: Any) -> int:
    """Length of ``value`` as ``Bridge`` encodes it on the line."""
    return len(json.dumps(value, separators=(",", ":")))


def _canonical(name: str) -> str:
    """The spelling the bridge stores, so two names for one block compare equal here too."""
    return format_name(*parse_name(name))


@dataclass(frozen=True)
class _At:
    x: int
    y: int
    z: int

    def __post_init__(self) -> None:
        for name in "xyz":
            object.__setattr__(self, name, int(getattr(self, name)))


@dataclass(frozen=True)
class SetBlock(_At):
    block: str
    blocks = 1

    def __post_init__(self) -> None:
        super().__post_init__()
        object.__setattr__(self, "block", _canonical(self.block))

    @property
    def bounds(self) -> Bounds:
        return Bounds((self.x, self.y, self.z), (self.x, self.y, self.z))

    def paint(self, region: Region) -> None:
        region.set(self.x, self.y, self.z, self.block)

    def to_json(self) -> dict[str, Any]:
        return {"op": "set_block", "pos": [self.x, self.y, self.z], "block": self.block}


@dataclass(frozen=True)
class Fill:
    bounds: Bounds
    block: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "block", _canonical(self.block))

    @property
    def blocks(self) -> int:
        return self.bounds.volume

    def paint(self, region: Region) -> None:
        region.fill(self.bounds, self.block)

    def to_json(self) -> dict[str, Any]:
        return {"op": "fill", "bounds": self.bounds.to_json(), "block": self.block}


@dataclass(frozen=True)
class Replace:
    bounds: Bounds
    from_block: tuple[str, ...]
    to_block: str

    def __post_init__(self) -> None:
        names = (self.from_block,) if isinstance(self.from_block, str) else tuple(self.from_block)
        object.__setattr__(self, "from_block", tuple(_canonical(name) for name in names))
        object.__setattr__(self, "to_block", _canonical(self.to_block))

    @property
    def blocks(self) -> int:
        return self.bounds.volume

    def paint(self, region: Region) -> None:
        region.replace(self.bounds, self.from_block, self.to_block)

    def to_json(self) -> dict[str, Any]:
        return {"op": "replace", "bounds": self.bounds.to_json(), "from": list(self.from_block), "to": self.to_block}


@dataclass(frozen=True)
class Text(_At):
    """Floating text. It changes no block, so it has no bounds and counts for nothing."""

    text: str
    id: str | None = None
    bounds, blocks = None, 0

    def to_json(self) -> dict[str, Any]:
        return {"op": "text", "pos": [self.x, self.y, self.z], "text": self.text, "id": self.id}


Op = SetBlock | Fill | Replace | Text


def _op_from_json(data: dict[str, Any]) -> Op:
    kind = data.get("op")
    if kind == "set_block":
        return SetBlock(*data["pos"], data["block"])
    if kind == "fill":
        return Fill(Bounds.from_json(data["bounds"]), data["block"])
    if kind == "replace":
        return Replace(Bounds.from_json(data["bounds"]), data["from"], data["to"])
    if kind == "text":
        return Text(*data["pos"], data["text"], data.get("id"))
    raise ValueError(f"unknown op {kind!r}")


def _run_key(item: tuple[int, Op]) -> Any:
    """Equal across consecutive ``SetBlock``s of one block stepping +1 along x at one y and z."""
    i, op = item
    return (op.y, op.z, op.block, op.x - i) if isinstance(op, SetBlock) else i


def _tiled(op: Op) -> list[Op]:
    """A ``Fill`` or ``Replace`` as one op per ``MAX_EDGE`` tile of its bounds; any other op as is."""
    if isinstance(op, (Fill, Replace)):
        return [dataclasses.replace(op, bounds=tile) for tile in op.bounds.tiles(MAX_EDGE)]
    return [op]


@dataclass
class ApplyResult:
    ok: bool
    jobs: list[dict[str, Any]] = field(default_factory=list)
    blocks: int = 0
    errors: list[Exception] = field(default_factory=list)
    before_result: Any = None


@dataclass
class EditList:
    world: str
    ops: list[Op] = field(default_factory=list)
    extras: dict[str, Any] = field(default_factory=dict)

    @property
    def bounds(self) -> Bounds | None:
        """Union of every block op's bounds; ``None`` when no op touches a block."""
        boxes = [op.bounds for op in self.ops if op.bounds is not None]
        return reduce(Bounds.union, boxes) if boxes else None

    def count_blocks(self) -> int:
        return sum(op.blocks for op in self.ops)

    def coalesce(self) -> EditList:
        """Runs of ``COALESCE_RUN`` or more become a ``Fill``; order is kept, so the same region is painted."""
        out: list[Op] = []
        for _, group in groupby(enumerate(self.ops), key=_run_key):
            run = [op for _, op in group]
            if len(run) >= COALESCE_RUN:
                out.append(Fill(run[0].bounds.union(run[-1].bounds), run[0].block))
            else:
                out.extend(run)
        return EditList(self.world, out, dict(self.extras))

    def to_region(self, base: Region | None = None) -> Region:
        """The ops painted in order onto a copy of ``base``, or onto air over ``bounds``."""
        if base is None:
            box = self.bounds
            if box is None:
                raise ValueError("an edit list with no block ops has no bounds; pass a base region")
            region = Region.empty(self.world, box)
        else:
            if base.world != self.world:
                raise ValueError(f"base region is from world {base.world!r}, edits are for {self.world!r}")
            region = Region(base.world, base.bounds, base.blocks.copy(), list(base.palette))
        for op in [op for op in self.ops if op.bounds is not None]:
            if region.bounds.intersect(op.bounds) != op.bounds:
                raise ValueError(f"{type(op).__name__} at {op.bounds.min}..{op.bounds.max} is outside {region.bounds.min}..{region.bounds.max}")
            op.paint(region)
        return region

    def to_json(self) -> dict[str, Any]:
        return {"world": self.world, "ops": [op.to_json() for op in self.ops], "extras": self.extras}

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> EditList:
        return cls(data["world"], [_op_from_json(op) for op in data["ops"]], dict(data.get("extras") or {}))

    def requests(self, batch: int = DEFAULT_BATCH) -> list[tuple[str, dict[str, Any], int]]:
        """What ``apply`` sends, in order, as ``(op, args, blocks)``.

        ``SetBlock``s pack into ``set_blocks`` of at most ``batch`` and at most
        ``MAX_LINE_BYTES`` on the wire; a ``Fill`` or ``Replace`` is one request
        per ``MAX_EDGE`` tile; a ``Text`` is one. Any other request too long
        for one line is refused here, before ``apply`` sends anything.
        """
        if not 1 <= batch <= MAX_SET_BLOCKS:
            raise ValueError(f"batch must be between 1 and {MAX_SET_BLOCKS}, got {batch}")
        out: list[tuple[str, dict[str, Any], int]] = []
        pending: list[list[Any]] = []
        empty = _wire_bytes({"world": self.world, "blocks": []})
        size = empty
        for op in self.ops + [None]:
            if isinstance(op, SetBlock):
                entry = [op.x, op.y, op.z, op.block]
                # One more for the comma that separates it from the entry before.
                cost = _wire_bytes(entry) + 1
                if pending and (len(pending) == batch or size + cost > LINE_BUDGET):
                    out.append(("set_blocks", {"world": self.world, "blocks": pending}, len(pending)))
                    pending, size = [], empty
                pending.append(entry)
                size += cost
                continue
            if pending:
                out.append(("set_blocks", {"world": self.world, "blocks": pending}, len(pending)))
                pending, size = [], empty
            for piece in [] if op is None else _tiled(op):
                # The JSON form of a fill, replace or text op is its wire args, minus an unset text id.
                args = {"world": self.world, **piece.to_json()}
                kind = args.pop("op")
                args = {k: v for k, v in args.items() if v is not None}
                if (length := _wire_bytes(args)) > LINE_BUDGET:
                    raise ValueError(f"a {kind} op of {length} bytes does not fit max_line_bytes ({MAX_LINE_BYTES})")
                out.append(("set_text" if kind == "text" else kind, args, piece.blocks))
        return out

    def apply(
        self, bridge: Bridge, *, dry_run: bool = False, batch: int = DEFAULT_BATCH,
        on_progress: Callable[[int, int], None] | None = None,
        before: Callable[[str, Bounds], Any] | None = None,
    ) -> ApplyResult:
        """Send in order, stopping at the first ``BridgeError``; ``before`` runs once ahead of the first request when a block is touched."""
        requests, result = self.requests(batch), ApplyResult(True)
        if dry_run:
            return result
        if before is not None and (box := self.bounds) is not None:
            result.before_result = before(self.world, box)
        total = self.count_blocks()
        for op, args, blocks in requests:
            progress = None if on_progress is None else lambda done, _, base=result.blocks: on_progress(base + done, total)
            try:
                if op == "set_text":
                    status = {"op": op, "state": "done", "result": bridge.call(op, **args)}
                else:
                    status = bridge.call_job(op, on_progress=progress, **args)
            except BridgeError as exc:
                result.ok = False
                result.errors.append(exc)
                return result
            result.jobs.append(status)
            result.blocks += blocks
        return result
