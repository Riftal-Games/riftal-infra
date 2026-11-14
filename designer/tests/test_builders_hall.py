import json

import numpy as np
import pytest

from designer.blocks import AIR
from designer.bridge import Bridge
from designer.builders import BUILDERS
from designer.builders.base import Palette
from designer.builders.hall import HallSpec, build_hall
from designer.builders.mine import build_mine
from designer.config import PROJECT_ROOT
from designer.edits import EditList, SetBlock
from designer.level import open_carve
from designer.palettes import HALL_ROLES, load_palettes
from designer.region import Bounds, Region
from tests.fake_bridge import FakeBridge, FakeWorld

STONE = "minecraft:stone"
TIERS = {"hall_mine_a": "mine_a", "hall_mine_b": "mine_b", "hall_mine_c": "mine_c", "hall_lumber": "lumber"}
# What each zone's mines config yields. A block of any ore-ladder material outside its own is a tier it does not belong to.
YIELDS = {"mine_a": {"coal"}, "mine_b": {"copper", "iron"}, "mine_c": {"iron", "lapis"}, "lumber": set()}
ORE_WORDS = ("coal", "copper", "iron", "lapis", "gold", "diamond", "emerald", "redstone")


def _mine(zone: str, side: str = "south") -> dict:
    data = json.loads((PROJECT_ROOT / "specs" / f"{zone}.json").read_text(encoding="utf-8"))
    return {**data, "entrance": {**data["entrance"], "side": side}}


def _names(region: Region, box: Bounds) -> np.ndarray:
    view = region.sub(box)
    return np.array(view.palette, dtype=object)[view.blocks]


def _built(zone: str, palette: str, side: str = "south", **over: object) -> tuple[Region, Region, HallSpec, EditList]:
    """The terrain with the mine built into it, that with the hall dug on top, and the hall's spec and edits."""
    spec = HallSpec.from_dict({"mine": _mine(zone, side), **over})
    land = Region.empty(spec.mine.world, spec.mine.geometry().padding.expand(16), STONE)
    mine = build_mine(spec.mine, Palette.load("mine_stone")).to_region(land)
    edits = build_hall(spec, Palette.load(palette))
    return mine, edits.to_region(mine), spec, edits


@pytest.mark.parametrize("palette", TIERS)
def test_every_tier_palette_binds_exactly_the_hall_roles(palette: str) -> None:
    assert set(load_palettes()["palettes"][palette]) == set(HALL_ROLES)


@pytest.mark.parametrize("palette, zone", TIERS.items())
def test_a_tier_shows_only_the_ore_materials_its_mine_yields(palette: str, zone: str) -> None:
    roles = load_palettes()["palettes"][palette]
    shown = {word for block in roles.values() for word in ORE_WORDS if word in block}
    assert shown <= YIELDS[zone]


@pytest.mark.parametrize("over, match", [
    ({"height": 3}, "height must be at least"),
    ({"half_width": 1}, "half_width"),
    ({"half_width": 4, "gap": 3}, "gap must be 0..2"),
])
def test_from_dict_refuses_a_hall_that_does_not_fit(over: dict, match: str) -> None:
    with pytest.raises(ValueError, match=match):
        HallSpec.from_dict({"mine": _mine("mine_a"), **over})


def test_from_dict_refuses_a_missing_mine() -> None:
    with pytest.raises(ValueError, match=r"missing \['mine'\]"):
        HallSpec.from_dict({})


def test_the_registry_builds_a_hall_from_its_spec_dict() -> None:
    edits = BUILDERS["hall"]({"mine": _mine("mine_a")}, Palette.load("hall_mine_a"), lambda *_: None)
    assert edits.world == "mine_a" and edits.ops


@pytest.mark.parametrize("palette, zone, over", [
    ("hall_mine_a", "mine_a", {}), ("hall_mine_b", "mine_b", {"half_width": 5}), ("hall_mine_c", "mine_c", {"height": 5}),
    ("hall_lumber", "lumber", {"gap": 1}),
])
@pytest.mark.parametrize("side", ["south", "north", "east", "west"])
def test_the_hall_leaves_the_mine_untouched_and_puts_the_gate_trim_on_the_outer_face(palette: str, zone: str, over: dict, side: str) -> None:
    before, after, spec, edits = _built(zone, palette, side, **over)
    geo = spec.mine.geometry()
    walking = Bounds((geo.exit_platform.min[0], spec.mine.floor_y, geo.exit_platform.min[2]), (geo.exit_platform.max[0], spec.mine.floor_y + 1, geo.exit_platform.max[2]))
    for box in (geo.interior, geo.entrance, walking):
        assert (_names(before, box) == _names(after, box)).all()
    assert all(op.bounds.intersect(geo.interior) is None for op in edits.ops)
    assert all(op.bounds.intersect(geo.entrance) is None for op in edits.ops)
    outer, i = geo.outer, 0 if side in ("east", "west") else 2
    [key] = [op for op in edits.ops if isinstance(op, SetBlock) and op.block == Palette.load(palette).block("keystone")]
    assert (key.x, key.y, key.z)[i] == (outer.max[i] if side in ("south", "east") else outer.min[i])


@pytest.mark.parametrize("palette, zone", [("hall_mine_a", "mine_a"), ("hall_lumber", "lumber")])
def test_the_hall_leaves_every_named_cell_as_the_mine_built_it(palette: str, zone: str) -> None:
    before, after, spec, _ = _built(zone, palette, gap=1 if zone == "lumber" else 0)
    locations = [Bounds(tuple(loc["pos"]), tuple(loc["pos"])) for loc in build_mine(spec.mine, Palette.load("mine_stone")).extras["locations"]]
    for cell in locations:
        assert (_names(before, cell) == _names(after, cell)).all()


def test_the_hall_is_dressed_where_a_player_standing_at_the_spawn_looks() -> None:
    _, after, spec, edits = _built("mine_a", "hall_mine_a")
    # Mine A faces south: the lane is x 0, the NPCs stand at z 23, the hall is z 18..23 and the shell's face z 17.
    assert after.get(-2, 41, 24) == "minecraft:yellow_concrete" and after.get(2, 41, 24) == "minecraft:blue_concrete"
    assert after.get(-1, 39, 23) == "minecraft:yellow_wool" and after.get(1, 39, 23) == "minecraft:blue_wool"
    assert after.get(0, 41, 24) == STONE
    assert after.get(4, 41, 19) == "minecraft:chiseled_stone_bricks" and after.get(4, 41, 20) == AIR
    assert after.get(3, 43, 19) == "minecraft:lantern[hanging=true]"
    assert after.get(-3, 41, 17) == "minecraft:coal_block" and after.get(0, 44, 17) == "minecraft:coal_block"
    assert [box["min"] for box in edits.extras["carve"]] == [[-4, 40, 18], [2, 40, 18], [-1, 42, 18]]


def test_a_slab_is_written_with_the_state_the_core_requires() -> None:
    _, after, _, _ = _built("mine_a", "hall_mine_a")
    assert after.get(0, 45, 17) == "minecraft:stone_brick_slab[minecraft:vertical_half=bottom]"


@pytest.fixture
def world(fake: FakeBridge, bridge: Bridge) -> Bridge:
    fake.worlds["mine_a"] = FakeWorld(extent=((-64, -64), (64, 64)))
    return bridge


def _carving(box: dict) -> EditList:
    return EditList("mine_a", [], {"carve": [box]})


def test_a_carve_through_solid_terrain_is_allowed(world: Bridge) -> None:
    assert open_carve(world, _carving({"min": [-4, 40, 18], "max": [4, 43, 23]})) is None


def test_a_carve_that_reaches_air_is_refused_and_names_the_cell(world: Bridge) -> None:
    found = open_carve(world, _carving({"min": [-4, 60, 18], "max": [4, 66, 23]}))
    assert found is not None and "(-4, 64, 18) holds minecraft:air" in found
