"""``pit_matches_handoff``: the pit read back from the server against the studio's hand-off (plan 4.4).

Thirteen numbered checks over one ``Region`` of the whole build box, each returning its counts
and the positions that break it. The counts go into the level's lock, so a build records what
it was measured against. Coordinates in the hand-off's data files are local, and
``world = local + origin``.
"""

from __future__ import annotations

import json
import tempfile
from collections import Counter
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from designer.blocks import AIR, BlockClass, class_lut, format_name, parse_name
from designer.region import Bounds, Region
from designer.structure import CELL, StructureSpec, convert
from designer.verify import MARGIN_Y, Check, Pos, path_exists

# Bedrock's colour id for gray. The read-back carries no block entities, so a bed's colour is read from the cell files.
GRAY = 7
PLACEHOLDER = "minecraft:packed_mud"
# Bedrock's id for plain terracotta is hardened_clay, which routes.json spells terracotta.
TERRACOTTA = ("minecraft:hardened_clay", "minecraft:terracotta")
LIQUIDS = (
    "minecraft:water", "minecraft:flowing_water", "minecraft:lava", "minecraft:flowing_lava",
    "minecraft:bubble_column", "minecraft:kelp", "minecraft:seagrass",
)
# A ladder's ``facing_direction`` state is Bedrock's face id.
FACING = {"north": "2", "south": "3", "west": "4", "east": "5"}
# Layers 1 to 8 hang a lantern, 9 and deeper a soul lantern.
LANTERN_LAYERS = 8
# The floor ring is the fourteenth layer's mine.
RING_LAYER = 14
# The positions INTEGRATION.md quotes after the origin shift, as (local, world).
SAMPLES = {
    "south stairway layer 1 bottom landing": ((11, 142, 122), (11, 208, 122)),
    "contested_mine_top": ((0, -121, 6), (0, -55, 6)),
    "deck_1": ((0, 142, 34), (0, 208, 34)),
    "hall": ((0, -118, 23), (0, -52, 23)),
    "cell L08-R2-010 door_lower": ((75, 7, -24), (75, 73, -24)),
}
# The first layers walked from terrace to deck over a bridge.
BRIDGE_LEGS = 3
LEG_MARGIN = 16
SHOWN = 5

Problem = tuple[str, Pos | None]
Found = dict[str, tuple[dict[str, Any], list[Problem]]]
Test = Callable[[str, dict[str, str]], bool]
Cells = dict[Pos, dict[str, Any]]
Shape = tuple[str, Bounds, Sequence[str], Sequence[float], str, Callable[[np.ndarray, np.ndarray], np.ndarray]]


@dataclass(frozen=True)
class Handoff:
    """The hand-off's data files and the box the build puts them in."""

    origin: Pos
    box: Bounds
    cells: list[dict[str, Any]]
    ladders: list[dict[str, Any]]
    routes: dict[str, Any]
    census: dict[str, Any]

    @classmethod
    def load(cls, spec: StructureSpec, root: Path) -> Handoff:
        def read(name: str) -> Any:
            return json.loads((root / spec.source / name).read_text(encoding="utf-8"))

        cells = read("cells.json")
        return cls(spec.origin, build_box(spec, root), cells["cells"], cells["ladders"], read("routes.json"), read("census.json"))

    def at(self, local: Sequence[int]) -> Pos:
        return (local[0] + self.origin[0], local[1] + self.origin[1], local[2] + self.origin[2])


def build_box(spec: StructureSpec, root: Path) -> Bounds:
    """The box the structure fills once placed: its census size from its minimum corner."""
    census = json.loads((root / spec.source / "census.json").read_text(encoding="utf-8"))
    return Bounds.from_size(spec.world_min(), census["size"])


def source_cells(source: Path, spec: StructureSpec) -> Cells:
    """The source cut into cell documents by the ``convert`` the build loads, keyed by corner."""
    with tempfile.TemporaryDirectory() as out:
        converted = convert(source, Path(out), spec)
        return {(x, y, z): json.loads((Path(out) / c["file"]).read_text(encoding="utf-8")) for c in converted.cells for x, y, z in [c["at"]]}


def expected_blocks(docs: Cells, bounds: Bounds, ids: dict[str, int]) -> np.ndarray:
    """``blocks[y][z][x]`` over ``bounds`` as the cell documents say, air wherever none reaches.

    ``ids`` numbers canonical block names and grows with the ones the documents add.
    """
    out = np.zeros(bounds.shape, dtype=np.int16)
    for at, doc in docs.items():
        cell = Bounds(at, (at[0] + CELL - 1, at[1] + CELL - 1, at[2] + CELL - 1))
        if (inner := bounds.intersect(cell)) is None:
            continue
        lut = np.array([ids.setdefault(format_name(*parse_name(n)), len(ids)) for n in doc["palette"]], dtype=np.int16)
        blocks = lut[np.asarray(doc["blocks"], dtype=np.int64)].reshape(CELL, CELL, CELL)
        out[bounds.slices(inner)] = blocks[cell.slices(inner)]
    return out


class View:
    """A region with each palette entry parsed once, so a set of positions is read in one gather."""

    def __init__(self, region: Region) -> None:
        self.region = region
        self.parsed = [parse_name(name) for name in region.palette]
        self.classes = np.append(class_lut(region.palette), 255)
        self.low = np.array(region.bounds.min)

    def index(self, points: Sequence[Sequence[int]]) -> np.ndarray:
        """Palette index at each point, -1 for one outside the region."""
        pts = np.asarray(points, dtype=np.int64).reshape(-1, 3)
        inside = ((pts >= self.low) & (pts <= np.array(self.region.bounds.max))).all(axis=1)
        out = np.full(len(pts), -1, dtype=np.int64)
        x, y, z = (pts[inside] - self.low).T
        out[inside] = self.region.blocks[y, z, x]
        return out

    def is_(self, points: Sequence[Sequence[int]], test: Test) -> np.ndarray:
        return np.array([test(base, states) for base, states in self.parsed] + [False])[self.index(points)]

    def class_at(self, points: Sequence[Sequence[int]]) -> np.ndarray:
        return self.classes[self.index(points)]

    def name(self, pos: Sequence[int]) -> str:
        found = int(self.index([pos])[0])
        return self.region.palette[found] if found >= 0 else "nothing (outside the read-back)"

    def indices(self, bases: Sequence[str]) -> list[int]:
        return [i for i, (base, _) in enumerate(self.parsed) if base in bases]

    def first(self, mask: np.ndarray, n: int = SHOWN, low: Sequence[int] | None = None) -> list[Pos]:
        """World positions of the first ``n`` set cells of ``mask``, ``low`` the world position of its corner.

        Found slab by slab, so a build wrong everywhere costs no more memory than one that is wrong once.
        """
        x0, y0, z0 = self.low if low is None else low
        found: list[Pos] = []
        for iy in range(mask.shape[0]):
            for iz, ix in np.argwhere(mask[iy]):
                found.append((int(ix) + int(x0), iy + int(y0), int(iz) + int(z0)))
                if len(found) == n:
                    return found
        return found

    def totals(self) -> Counter[str]:
        counts = np.bincount(self.region.blocks.ravel(), minlength=len(self.parsed))
        out: Counter[str] = Counter()
        for (base, _), n in zip(self.parsed, counts.tolist(), strict=True):
            out[base] += n
        return out


def _is(*bases: str, **states: str) -> Test:
    return lambda base, have: base in bases and all(have.get(k) == v for k, v in states.items())


def _read_back(view: View, ref: Handoff, docs: Cells) -> Found:
    ids: dict[str, int] = {}
    seen = np.array([ids.setdefault(format_name(*parse_name(n)), len(ids)) for n in view.region.palette], dtype=np.int16)
    expected = expected_blocks(docs, view.region.bounds, ids)
    wrong = seen[view.region.blocks] != expected
    names = {i: n for n, i in ids.items()}
    problems = [
        (f"{pos} holds {view.name(pos)}, the source has {names[int(expected[view.region.bounds.local(pos)])]}", pos)
        for pos in view.first(wrong)
    ]
    return {"01_read_back": ({"cells": view.region.bounds.volume, "mismatches": int(wrong.sum())}, problems)}


def _placed(view: View, bases: Sequence[str], boxes: list[tuple[str, Bounds, int]], what: str) -> tuple[dict[str, int], list[Problem], int, list[Problem]]:
    """Cells of ``bases`` in each ``(label, box, wanted)``, the boxes that miss their count, then every cell outside all of them."""
    mask = np.isin(view.region.blocks, view.indices(bases))
    got: dict[str, int] = {}
    short: list[Problem] = []
    for label, box, wanted in boxes:
        inside = view.region.bounds.slices(box)
        got[label] = int(mask[inside].sum())
        if got[label] != wanted:
            gap = view.first(~mask[inside], 1, box.min) if wanted == box.volume else []
            short.append((f"{what} in {label}: {got[label]}, expected {wanted}" + (f", first missing at {gap[0]}" if gap else ""), gap[0] if gap else None))
        mask[inside] = False
    return got, short, int(mask.sum()), [(f"{what} at {pos}, outside every box", pos) for pos in view.first(mask)]


def _box(ref: Handoff, radius: int, y: Sequence[int]) -> Bounds:
    """The square of half-width ``radius`` round the pit axis over local ``y``, clipped to the build box."""
    low, high = ref.at((-radius, y[0], -radius)), ref.at((radius, y[1], radius))
    if (box := ref.box.intersect(Bounds(low, high))) is None:
        raise ValueError(f"the square of radius {radius} at y {tuple(y)} lies outside the build box")
    return box


def _mines(ref: Handoff) -> list[tuple[str, Bounds, int]]:
    """Each layer's placeholder box and count: the 13 deck beds, then the floor ring."""
    decks, ring = ref.routes["decks"], ref.routes["pit_floor"]["layer14_ring"]
    boxes = [(f"layer {d['deck']}", _box(ref, d["bed_r"][1], d["bed_y"]), d["bed_blocks"]) for d in decks]
    return [*boxes, (f"layer {RING_LAYER}", _box(ref, ring["r"][1], ring["y"]), ring["blocks"])]


def _mud(view: View, ref: Handoff, docs: Cells) -> Found:
    got, short, elsewhere, stray = _placed(view, (PLACEHOLDER,), _mines(ref), "packed_mud")
    return {"02_bed_placeholders": ({"per_layer": got, "total": sum(got.values())}, short), "03_placeholders_elsewhere": ({"count": elsewhere}, stray)}


def _contested(ref: Handoff) -> Bounds:
    mine = ref.routes["contested_mine"]
    return Bounds(ref.at(mine["box_min"]), ref.at(mine["box_max"]))


def _terracotta(view: View, ref: Handoff, docs: Cells) -> Found:
    mine = ref.routes["contested_mine"]
    got, short, elsewhere, stray = _placed(view, TERRACOTTA, [("the contested mine", _contested(ref), mine["blocks"])], "terracotta")
    return {"04_contested_mine": ({"in_cuboid": sum(got.values()), "elsewhere": elsewhere}, short + stray)}


def _cells(view: View, ref: Handoff, docs: Cells) -> Found:
    cells = ref.cells
    colours = {(at[0] + e["pos"][0], at[1] + e["pos"][1], at[2] + e["pos"][2]): e["color"] for at, doc in docs.items() for e in doc.get("block_entities", [])}
    layers = np.array([c["layer"] for c in cells])
    ok = np.ones(len(cells), dtype=bool)
    problems: list[Problem] = []

    def need(key: str, test: Test, what: str, rows: np.ndarray) -> None:
        points = [ref.at(cells[i][key]) for i in rows]
        for i, pos, good in zip(rows, points, view.is_(points, test), strict=True):
            if not good:
                ok[i] = False
                problems.append((f"cell {cells[i]['id']} {key} at {pos} holds {view.name(pos)}, not {what}", pos))

    every, shallow, deep = np.arange(len(cells)), np.flatnonzero(layers <= LANTERN_LAYERS), np.flatnonzero(layers > LANTERN_LAYERS)
    need("door_lower", _is("minecraft:iron_door", upper_block_bit="false"), "the lower half of an iron door", every)
    need("door_upper", _is("minecraft:iron_door", upper_block_bit="true"), "the upper half of an iron door", every)
    need("button_outside", _is("minecraft:stone_button"), "a stone button", every)
    need("plate_inside", _is("minecraft:stone_pressure_plate"), "a stone pressure plate", every)
    need("chest", _is("minecraft:chest"), "a chest", every)
    need("bed_head", _is("minecraft:bed", head_piece_bit="true"), "the head of a bed", every)
    need("bed_foot", _is("minecraft:bed", head_piece_bit="false"), "the foot of a bed", every)
    need("light", _is("minecraft:lantern"), "a lantern", shallow)
    need("light", _is("minecraft:soul_lantern"), "a soul lantern", deep)
    for i, cell in enumerate(cells):
        for key in ("bed_head", "bed_foot"):
            pos = ref.at(cell[key])
            if colours.get(pos) != GRAY:
                ok[i] = False
                problems.append((f"cell {cell['id']} {key} at {pos} has colour {colours.get(pos)}, not gray ({GRAY})", pos))
        low, high = ref.at(cell["interior_min"]), ref.at(cell["interior_max"])
        points = [(x, y, z) for x in range(low[0], high[0] + 1) for y in range(low[1], high[1] + 1) for z in range(low[2], high[2] + 1)]
        known = {ref.at(cell[k]) for k in ("plate_inside", "chest", "bed_head", "bed_foot", "light")}
        if stray := [p for p, air in zip(points, view.is_(points, _is(AIR)), strict=True) if not air and p not in known]:
            ok[i] = False
            problems.append((f"cell {cell['id']} interior holds {view.name(stray[0])} at {stray[0]}, not air", stray[0]))
    per_layer = Counter(layer for layer, good in zip(layers.tolist(), ok.tolist(), strict=True) if good)
    counts = {"cells": len(cells), "cells_ok": int(ok.sum()), "per_layer": {str(k): per_layer[k] for k in sorted(set(layers.tolist()))}}
    return {"05_cells": (counts, problems)}


def _census(view: View, ref: Handoff, docs: Cells) -> Found:
    n = len(ref.cells)
    wanted = {"minecraft:iron_door": 2 * n, "minecraft:chest": n, "minecraft:bed": 2 * n}
    have, census = view.totals(), ref.census["block_names"]
    problems: list[Problem] = [
        (f"{base}: {have[base]} in the world, {census.get(base, 0)} in the census, {count} from cells.json", None)
        for base, count in wanted.items() if not have[base] == census.get(base, 0) == count
    ]
    if problems:
        known = {ref.at(c[k]) for c in ref.cells for k in ("door_lower", "door_upper", "chest", "bed_head", "bed_foot")}
        mask = np.isin(view.region.blocks, view.indices(tuple(wanted)))
        extra = [p for p in view.first(mask, len(known) + SHOWN) if p not in known]
        problems += [(f"{view.name(p)} at {p} belongs to no cell in cells.json", p) for p in extra[:SHOWN]]
    return {"06_census": ({"iron_door_halves": have["minecraft:iron_door"], "chests": have["minecraft:chest"], "beds": have["minecraft:bed"]}, problems)}


def _ladders(view: View, ref: Handoff, docs: Cells) -> Found:
    ok, problems = 0, []
    for ladder in ref.ladders:
        points = [ref.at((ladder["x"], y, ladder["z"])) for y in range(ladder["y_from"], ladder["y_to"] + 1)]
        good = view.is_(points, _is("minecraft:ladder", facing_direction=FACING[ladder["facing"]]))
        if good.all():
            ok += 1
            continue
        pos = points[int(np.argmin(good))]
        what = f"layer {ladder['layer']} ladder at x {ladder['x']} z {ladder['z']}"
        problems.append((f"{what}: {int((~good).sum())} of {len(points)} blocks are not a ladder facing {ladder['facing']}, first {view.name(pos)} at {pos}", pos))
    return {"07_ladders": ({"ladders": len(ref.ladders), "ladders_ok": ok}, problems)}


def _standable(view: View, ref: Handoff, docs: Cells) -> Found:
    routes = ref.routes
    points = [(f"{s['stair']} stairway layer {s['layer']} {end}", ref.at(s[end])) for s in routes["stairs"] for end in ("top_landing", "bottom_landing")]
    points += [(f"warp {name}", ref.at(warp["local"])) for name, warp in routes["warps"].items()]
    points += [(f"bridge {b['name']} {end}", ref.at(b[end])) for b in routes["bridges"] for end in ("tower_end", "terrace_end")]
    at = np.array([p for _, p in points])
    below, feet, head = (view.class_at(at + (0, dy, 0)) for dy in (-1, 0, 1))
    good = (below == BlockClass.SOLID) & (feet == BlockClass.AIR) & (head == BlockClass.AIR)
    problems: list[Problem] = [
        (f"{label} at {pos}: {view.name((pos[0], pos[1] - 1, pos[2]))} below, {view.name(pos)} to stand in, {view.name((pos[0], pos[1] + 1, pos[2]))} above", pos)
        for (label, pos), ok in zip(points, good.tolist(), strict=True) if not ok
    ]
    return {"08_standable": ({"points": len(points), "points_ok": int(good.sum())}, problems)}


def _legs(ref: Handoff) -> list[tuple[str, Pos, Pos]]:
    warps = ref.routes["warps"]
    flights = sorted((s for s in ref.routes["stairs"] if s["stair"] == "south"), key=lambda s: s["layer"])
    legs = [("rim_south to the south stairway", ref.at(warps["rim_south"]["local"]), ref.at(flights[0]["top_landing"]))]
    for here, after in zip(flights, [*flights[1:], None], strict=True):
        legs.append((f"south stairway layer {here['layer']} flight", ref.at(here["top_landing"]), ref.at(here["bottom_landing"])))
        end = ref.at(warps["pit_floor"]["local"] if after is None else after["top_landing"])
        legs.append((f"south stairway layer {here['layer']} bottom landing onward", ref.at(here["bottom_landing"]), end))
    legs.append(("gate_outside to gate_hall", ref.at(warps["gate_outside"]["local"]), ref.at(warps["gate_hall"]["local"])))
    legs.append(("gate_hall to terrace 8", ref.at(warps["gate_hall"]["local"]), ref.at(warps["layer_8"]["local"])))
    legs.append(("pit_floor to hall", ref.at(warps["pit_floor"]["local"]), ref.at(warps["hall"]["local"])))
    return legs


def _deck_legs(ref: Handoff) -> list[tuple[str, Pos, Pos, tuple[Pos, Pos]]]:
    """A terrace's warp to its deck's warp, with the ends of the deck's bridge nearest the terrace warp, so the search corridor holds the bridge."""
    warps, legs = ref.routes["warps"], []
    for k in (deck["deck"] for deck in ref.routes["decks"][:BRIDGE_LEGS]):
        a, b = ref.at(warps[f"layer_{k}"]["local"]), ref.at(warps[f"deck_{k}"]["local"])
        ends = [(ref.at(x["tower_end"]), ref.at(x["terrace_end"])) for x in ref.routes["bridges"] if x["layer"] == k]
        legs.append((f"layer_{k} to deck_{k}", a, b, min(ends, key=lambda e: abs(e[1][0] - a[0]) + abs(e[1][2] - a[2]))))
    return legs


def _walk(view: View, label: str, a: Pos, b: Pos, via: Sequence[Pos] = ()) -> Problem | None:
    box = Bounds(a, b)
    for pos in via:
        box = box.union(Bounds(pos, pos))
    corridor = view.region.bounds.intersect(box.expand(LEG_MARGIN, "xz").expand(MARGIN_Y, "y"))
    found = path_exists(view.region.sub(corridor), a, b, corridor=corridor) if corridor else None
    if found is not None and found.ok:
        return None
    return f"{label}: {'outside the read-back' if found is None else found.detail}, from {a} to {b}", a


def _walkable(view: View, ref: Handoff, docs: Cells) -> Found:
    legs = [(*leg, ()) for leg in _legs(ref)] + _deck_legs(ref)
    problems = [found for label, a, b, via in legs if (found := _walk(view, label, a, b, via))]
    return {"09_walkable": ({"legs": len(legs), "legs_ok": len(legs) - len(problems)}, problems)}


def _samples(view: View, ref: Handoff, docs: Cells) -> Found:
    flight = next(s for s in ref.routes["stairs"] if s["stair"] == "south" and s["layer"] == 1)
    door = next(c for c in ref.cells if c["id"] == "L08-R2-010")
    warps = ref.routes["warps"]
    data = {
        "south stairway layer 1 bottom landing": flight["bottom_landing"], "contested_mine_top": warps["contested_mine_top"]["local"],
        "deck_1": warps["deck_1"]["local"], "hall": warps["hall"]["local"], "cell L08-R2-010 door_lower": door["door_lower"],
    }
    problems: list[Problem] = []
    for name, (local, world) in SAMPLES.items():
        if tuple(data[name]) != local or ref.at(local) != world:
            problems.append((f"{name}: the data has local {tuple(data[name])}, which lands at {ref.at(data[name])}; INTEGRATION.md has {local} and {world}", None))
        elif name.startswith("cell"):
            if not view.is_([world], _is("minecraft:iron_door", upper_block_bit="false"))[0]:
                problems.append((f"{name} at {world} holds {view.name(world)}, not an iron door", world))
        elif (view.class_at([(world[0], world[1] - 1, world[2])])[0], view.class_at([world])[0]) != (BlockClass.SOLID, BlockClass.AIR):
            problems.append((f"{name} at {world} is not air above a solid block", world))
    return {"10_samples": ({"samples": len(SAMPLES), "samples_ok": len(SAMPLES) - len(problems)}, problems)}


def _liquids(view: View, ref: Handoff, docs: Cells) -> Found:
    have, source = view.totals(), ref.census["block_names"]
    problems: list[Problem] = []
    for base in LIQUIDS:
        if have[base] > source.get(base, 0):
            first = view.first(np.isin(view.region.blocks, view.indices((base,))), 1)[0]
            problems.append((f"{have[base]} {base}, the source has {source.get(base, 0)}, first at {first}", first))
    return {"11_liquids": ({base.removeprefix("minecraft:"): have[base] for base in LIQUIDS}, problems)}


def _cells_in(view: View, box: Bounds, bases: Sequence[str]) -> np.ndarray:
    """World ``(x, y, z)`` of each cell of ``bases`` in ``box``, one row per cell."""
    ys, zs, xs = np.nonzero(np.isin(view.region.blocks[view.region.bounds.slices(box)], view.indices(bases)))
    return np.stack([xs + box.min[0], ys + box.min[1], zs + box.min[2]], axis=1)


def _distance(ref: Handoff, at: np.ndarray, centre: Sequence[float]) -> np.ndarray:
    """Horizontal distance of each row of ``at`` from ``centre``, local ``(x, z)``."""
    return np.hypot(at[:, 0] - ref.origin[0] - centre[0], at[:, 2] - ref.origin[2] - centre[1])


def _shapes(ref: Handoff) -> list[Shape]:
    """Where each placeholder may lie: ``t`` is the distance from the tower axis, ``p`` from the pit axis."""
    routes = ref.routes
    mines, mine = _mines(ref), routes["contested_mine"]
    shapes: list[Shape] = []
    for deck, (label, box, _) in zip(routes["decks"], mines, strict=False):
        low, high = deck["bed_r"]
        shapes.append((label, box, (PLACEHOLDER,), deck["centre"], f"r_t {low} to {high}", lambda t, p, low=low, high=high: (t >= low) & (t <= high)))
    inner, outer = routes["pit_floor"]["layer14_ring"]["r"]
    ring = (mines[-1][0], mines[-1][1], (PLACEHOLDER,), routes["decks"][0]["centre"], f"r_t {inner} or more and r under {outer}")
    shapes.append((*ring, lambda t, p: (t >= inner) & (p < outer)))
    shapes.append(("the contested mine", _contested(ref), TERRACOTTA, mine["centre"], f"r_t under {mine['radius']}", lambda t, p: t < mine["radius"]))
    return shapes


def _centres(view: View, ref: Handoff, docs: Cells) -> Found:
    seen, bad, problems = 0, 0, []
    for label, box, bases, centre, rule, inside in _shapes(ref):
        at = _cells_in(view, box, bases)
        wrong = ~inside(_distance(ref, at, centre), _distance(ref, at, (0, 0)))
        seen, bad = seen + len(at), bad + int(wrong.sum())
        for x, y, z in at[wrong][:SHOWN].tolist():
            problems.append((f"{label} placeholder at {(x, y, z)} lies outside {rule}", (x, y, z)))
    return {"12_two_centres": ({"placeholders": seen, "placeholders_ok": seen - bad}, problems)}


def _bridges(view: View, ref: Handoff, docs: Cells) -> Found:
    bridges, ok, problems = ref.routes["bridges"], 0, []
    for bridge in bridges:
        name, end, landing = bridge["name"], ref.at(bridge["terrace_end"]), bridge["landing"]
        found = [walk] if (walk := _walk(view, f"bridge {name} tower end to terrace end", ref.at(bridge["tower_end"]), end)) else []
        if not Bounds(ref.at(landing["box_min"]), ref.at(landing["box_max"])).contains(end):
            found.append((f"bridge {name} terrace end {end} lies outside the box of {landing['name']}", end))
        ok, problems = ok + (not found), problems + found
    return {"13_bridges": ({"bridges": len(bridges), "bridges_ok": ok}, problems)}


RUNNERS = (_read_back, _mud, _terracotta, _cells, _census, _ladders, _standable, _walkable, _samples, _liquids, _centres, _bridges)


def pit_matches_handoff(region: Region, ref: Handoff, docs: Cells, accepted: dict[str, list[str]] | None = None) -> Check:
    """The thirteen checks of plan 4.4 over ``region``, the whole build box, against ``docs``, the source's cell documents.

    ``accepted`` maps a check's number and name to the exact problem texts the hand-off is known to have, so
    those do not fail the build. An accepted text the check no longer finds fails it, so the list cannot go stale.
    ``data["counts"]`` holds each check's counts under its number and name.
    """
    view = View(region)
    found: Found = {}
    for run in RUNNERS:
        found.update(run(view, ref, docs))
    for name, texts in (accepted or {}).items():
        count, problems = found[name]
        seen = {text for text, _ in problems}
        kept = [problem for problem in problems if problem[0] not in texts]
        count["accepted_deviations"] = len(problems) - len(kept)
        found[name] = (count, kept + [(f"accepted deviation not found: {text}", None) for text in texts if text not in seen])
    counts = {name: count for name, (count, _) in found.items()}
    failed = {name: problems for name, (_, problems) in found.items() if problems}
    if not failed:
        return Check(True, "all thirteen checks hold", [], {"counts": counts})
    detail = "; ".join(
        f"check {name}: " + " | ".join(text for text, _ in problems[:SHOWN]) + (f" | and {len(problems) - SHOWN} more" if len(problems) > SHOWN else "")
        for name, problems in failed.items()
    )
    coords = [pos for problems in failed.values() for _, pos in problems[:SHOWN] if pos is not None]
    return Check(False, detail, coords, {"counts": counts})
