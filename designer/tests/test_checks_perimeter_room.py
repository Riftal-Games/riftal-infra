"""``checks.yaml``'s ``region_inside`` and ``no_holes`` entries against real ``build_perimeter``
and ``build_room`` output.

No builder emits a world's walkable footprint, so ``contested_walkable`` is authored into the
index by hand here, the way ``lumber_safe_zone`` sits in ``world_index.json``. The perimeter and
room specs, like ``test_checks_plot_signage.py``'s, are throwaway numbers sized only to give each
check something to pass or fail, not a proposal for the contested world's layout.
"""

import pytest

from designer.builders.base import Palette
from designer.builders.perimeter import PerimeterSpec, build_perimeter
from designer.builders.room import RoomSpec, build_room
from designer.checks import CheckSpec, RunContext, load_checks, run_one
from designer.region import Bounds
from designer.world_index import NamedRegion, WorldEntry, WorldIndex

BOUNDARY_ID, ROOM_ID = "region_inside_contested_boundary_contested_walkable", "no_holes_contested_room_66"

_PERIMETER = {"name": "contested_boundary", "world": "contested", "min": [0, 0], "max": [15, 15], "height": 3, "y": 65}
_ROOM = {
    "name": "contested_room", "world": "contested", "origin": [4, 65, 4], "size": [7, 4, 7],
    "wall_thickness": 1, "door": {"side": "south", "width": 2, "height": 2},
}
_WALKABLE = NamedRegion("contested_walkable", "contested", (-8, 64, -8), (23, 80, 23), ["walkway"])


def _index(*regions: dict) -> WorldIndex:
    index = WorldIndex(worlds=[WorldEntry("contested", "normal", 0, "contested")])
    index.add_region(_WALKABLE)
    for region in regions:
        index.add_region(NamedRegion.from_json(region))
    return index


def _checks() -> dict[str, CheckSpec]:
    return {c.id: c for c in load_checks() if c.id in (BOUNDARY_ID, ROOM_ID)}


def _room() -> tuple[WorldIndex, RunContext]:
    edits = build_room(RoomSpec.from_dict(_ROOM), Palette.load("mine_stone"))
    return _index(*edits.extras["regions"]), RunContext({edits.world: edits.to_region()})


def test_the_committed_checks_yaml_carries_both_entries() -> None:
    found = _checks()
    assert found.keys() == {BOUNDARY_ID, ROOM_ID}
    assert found[BOUNDARY_ID].kind == "region_inside" and found[ROOM_ID].kind == "no_holes"


def test_region_inside_passes_the_built_boundary_and_fails_one_built_off_the_footprint() -> None:
    spec, palette = _checks()[BOUNDARY_ID], Palette.load("mine_stone")
    built = build_perimeter(PerimeterSpec.from_dict(_PERIMETER), palette)
    assert run_one(RunContext({}), _index(*built.extras["regions"]), spec).ok

    stray = build_perimeter(PerimeterSpec.from_dict({**_PERIMETER, "max": [30, 15]}), palette)
    result = run_one(RunContext({}), _index(*stray.extras["regions"]), spec)
    assert not result.ok and "outside" in result.detail


def test_no_holes_passes_the_built_room_floor_inside_its_walls_and_fails_a_missing_floor_block() -> None:
    index, ctx = _room()
    spec = _checks()[ROOM_ID]
    assert run_one(ctx, index, spec).ok

    ctx.regions["contested"].fill(Bounds((6, 65, 6), (6, 65, 6)), "minecraft:air")
    result = run_one(ctx, index, spec)
    assert not result.ok and "1 holes" in result.detail and result.coords == [(6, 65, 6)]


def test_no_holes_counts_the_walls_as_holes_without_an_inset() -> None:
    index, ctx = _room()
    spec = _checks()[ROOM_ID]
    result = run_one(ctx, index, CheckSpec("h", "no_holes", {k: v for k, v in spec.args.items() if k != "inset"}))
    assert not result.ok and "holes" in result.detail


@pytest.mark.parametrize("inset, match", [(-1, "inset must be at least 0"), (4, "leaves nothing of"), (0.5, "inset must be an integer")])
def test_no_holes_fails_an_inset_that_is_negative_fractional_or_swallows_the_footprint(inset: object, match: str) -> None:
    index, ctx = _room()
    result = run_one(ctx, index, CheckSpec("h", "no_holes", {"region": "contested_room", "floor_y": 66, "inset": inset}))
    assert not result.ok and match in result.detail


def test_no_holes_fails_an_inset_of_exactly_half_the_short_side_when_that_side_runs_along_z() -> None:
    """A 10x6 footprint with inset 3: the square, odd room cannot tell ``>=`` from ``>`` or see a z-only
    overrun, and ``Bounds`` sorts its corners, so a missed overrun reads a flipped box instead of raising."""
    index, ctx = _room()
    index.add_region(NamedRegion("wide", "contested", (4, 65, 4), (13, 68, 9), []))
    result = run_one(ctx, index, CheckSpec("h", "no_holes", {"region": "wide", "floor_y": 66, "inset": 3}))
    assert not result.ok and "inset 3 leaves nothing of 'wide''s 10x6 footprint" in result.detail
