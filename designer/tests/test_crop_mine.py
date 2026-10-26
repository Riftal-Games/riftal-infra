import json

import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT
from designer.edits import SetBlock
from designer.region import Bounds, Region
from designer.verify import mine_valid

WET = "minecraft:farmland[moisturized_amount=7]"


def _crop_spec(**change: object) -> MineSpec:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    return MineSpec.from_dict({**data, "ores": {"minecraft:wheat": 1.0, "minecraft:carrots": 1.0}, **change})


def _built(spec: MineSpec) -> tuple[Region, Bounds]:
    geo = spec.geometry()
    edits = build_mine(spec, Palette.load("mine_stone"))
    return edits.to_region(Region.empty(spec.world, geo.padding.union(geo.exit_platform))), geo.interior


def test_a_crop_mine_writes_full_wetness_farmland_under_the_whole_crop_row() -> None:
    spec = _crop_spec()
    region, interior = _built(spec)
    floor = Bounds((interior.min[0], spec.floor_y - 1, interior.min[2]), (interior.max[0], spec.floor_y - 1, interior.max[2]))
    assert region.sub(floor).counts() == {WET: floor.volume}


def test_a_crop_mine_fragment_is_one_layer_with_floor_y_one_below_it() -> None:
    spec = _crop_spec()
    fragment = build_mine(spec, Palette.load("mine_stone")).extras["mine_reset"]
    interior = spec.geometry().interior
    assert fragment["floor_y"] == spec.floor_y - 1 == 39
    assert fragment["interior"] == {"min": [*interior.min[:1], 40, interior.min[2]], "max": [interior.max[0], 40, interior.max[2]]}
    assert fragment["interior"]["min"][1] == fragment["interior"]["max"][1] == fragment["floor_y"] + 1


def test_a_crop_mine_places_crops_in_its_bottom_row_only() -> None:
    spec = _crop_spec()
    ops = [op for op in build_mine(spec, Palette.load("mine_stone")).ops if isinstance(op, SetBlock)]
    crops = {op.y for op in ops if op.block in ("minecraft:wheat", "minecraft:carrots")}
    assert crops == {spec.floor_y}
    region, interior = _built(spec)
    above = Bounds((interior.min[0], spec.floor_y + 1, interior.min[2]), interior.max)
    assert region.sub(above).counts() == {"minecraft:air": above.volume}


def test_an_ore_mine_keeps_its_palette_floor_and_whole_interior() -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    spec = MineSpec.from_dict(data)
    fragment = build_mine(spec, Palette.load("mine_stone")).extras["mine_reset"]
    assert fragment["floor_y"] == spec.floor_y and fragment["interior"] == spec.geometry().interior.to_json()
    region, interior = _built(spec)
    assert WET not in region.sub(interior).counts() and WET not in region.counts()


def test_a_crop_mine_refuses_ore_layers() -> None:
    layers = [{"y_from": 40, "y_to": 40, "ores": {"minecraft:wheat": 1}}]
    with pytest.raises(ValueError, match="ore_layers"):
        _crop_spec(ore_layers=layers)


def test_the_built_hollow_crop_mine_passes_mine_valid() -> None:
    spec = _crop_spec(fill="hollow")
    region, _ = _built(spec)
    found = mine_valid(region, spec)
    assert found.ok and found.data["crop_floor_dry"] == 0, found.detail


@pytest.mark.parametrize("floor", [
    "minecraft:farmland[moisturized_amount=0]", "minecraft:farmland", "minecraft:dirt",
    "minecraft:water", "minecraft:farmland[moisturized_amount=x]", "minecraft:stone",
])
def test_one_cell_under_the_crop_row_that_is_not_wet_farmland_fails_the_build(floor: str) -> None:
    spec = _crop_spec(fill="hollow")
    region, interior = _built(spec)
    at = (interior.min[0] + 3, spec.floor_y - 1, interior.min[2] + 4)
    region.set(*at, floor)
    found = mine_valid(region, spec)
    assert not found.ok and found.data["crop_floor_dry"] == 1
    assert "1 crop floor cells are not farmland at wetness 1 or more" in found.detail and at in found.coords


def test_wetness_one_farmland_passes() -> None:
    spec = _crop_spec(fill="hollow")
    region, interior = _built(spec)
    region.set(interior.min[0], spec.floor_y - 1, interior.min[2], "minecraft:farmland[moisturized_amount=1]")
    assert mine_valid(region, spec).ok


def test_an_ore_mine_over_dirt_is_not_held_to_the_farmland_rule() -> None:
    data = json.loads((PROJECT_ROOT / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    spec = MineSpec.from_dict({**data, "fill": "hollow"})
    region, interior = _built(spec)
    region.fill(Bounds((interior.min[0], spec.floor_y - 1, interior.min[2]), (interior.max[0], spec.floor_y - 1, interior.max[2])), "minecraft:dirt")
    found = mine_valid(region, spec)
    assert found.ok and found.data["crop_floor_dry"] == 0


# The six blocks core builds as a Crops subclass: Wheat, Carrot, Potato, Beetroot, MelonStem, PumpkinStem.
@pytest.mark.parametrize("crop", ["wheat", "carrots", "potatoes", "beetroot", "melon_stem", "pumpkin_stem"])
def test_every_crop_block_makes_a_crop_mine(crop: str) -> None:
    spec = _crop_spec(ores={f"minecraft:{crop}": 1.0})
    fragment = build_mine(spec, Palette.load("mine_stone")).extras["mine_reset"]
    assert spec.has_crop and fragment["floor_y"] == spec.floor_y - 1


def test_a_crop_named_only_in_an_ore_layer_still_refuses_layers() -> None:
    layers = [{"y_from": 40, "y_to": 40, "ores": {"minecraft:wheat": 1}}]
    with pytest.raises(ValueError, match="ore_layers"):
        _crop_spec(ores={"minecraft:stone": 1.0}, ore_layers=layers)


def test_the_wetness_state_on_a_block_that_is_not_farmland_fails_the_build() -> None:
    spec = _crop_spec(fill="hollow")
    region, interior = _built(spec)
    region.set(interior.min[0], spec.floor_y - 1, interior.min[2], "minecraft:dirt[moisturized_amount=7]")
    found = mine_valid(region, spec)
    assert not found.ok and found.data["crop_floor_dry"] == 1
