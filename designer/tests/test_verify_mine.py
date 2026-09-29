import pytest

from designer.blocks import AIR
from designer.builders.mine_spec import MineSpec
from designer.region import Bounds, Region
from designer.verify import mine_valid
from tests.conftest import MINE_SPEC

Fixture = tuple[Region, MineSpec]


def test_geometry_of_the_fixture_spec_is_pinned(box_mine_region: Fixture) -> None:
    geo = box_mine_region[1].geometry()
    assert geo.outer == Bounds((0, 0, 0), (19, 9, 19))
    assert geo.interior == Bounds((2, 2, 2), (17, 7, 17))
    assert geo.entrance == Bounds((9, 2, 0), (11, 4, 1))
    assert geo.exit_platform == Bounds((9, 1, -5), (11, 1, -1))
    assert geo.padding == Bounds((-1, -1, -1), (20, 10, 20))
    east = MineSpec.from_dict({**MINE_SPEC, "entrance": {"side": "east", "width": 2, "height": 2, "offset": 3}}).geometry()
    assert east.entrance == Bounds((18, 2, 12), (19, 3, 13)) and east.exit_platform == Bounds((20, 1, 12), (24, 1, 14))


def test_from_dict_rejects_a_spec_that_does_not_fit() -> None:
    broken = (
        ({"size": [4, 10, 20]}, "interior"), ({"entrance": {"side": "up", "width": 3, "height": 3}}, "side"),
        ({"entrance": {"side": "north", "width": 17, "height": 3}}, "fit"), ({"floor_y": 0}, "floor_y"),
        ({"ores": {"stone": -1}}, "positive"), ({"ore_layers": [{"y_from": 0, "y_to": 3, "ores": {"stone": 1}}]}, "outside"),
        ({"fill": "sparse"}, "fill"), ({"reset_percent": 0}, "reset_percent"), ({"origin": 0}, "malformed"),
        ({"ore_layers": [{"y_from": 2, "y_to": 4, "ores": {"stone": 1}}, {"y_from": 4, "y_to": 5, "ores": {"stone": 1}}]}, "overlap"),
        ({"ore_layers": [{"y_from": 2, "y_to": 2}]}, "malformed"), ({"entrance": {"width": 3, "height": 3}}, "malformed"),
    )
    for change, match in broken:
        with pytest.raises(ValueError, match=match):
            MineSpec.from_dict({**MINE_SPEC, **change})
    with pytest.raises(ValueError, match="missing"):
        MineSpec.from_dict({k: v for k, v in MINE_SPEC.items() if k != "ores"})


def test_the_box_mine_is_valid(box_mine_region: Fixture) -> None:
    region, spec = box_mine_region
    found = mine_valid(region, spec)
    assert found.ok and found.detail == "mine valid" and found.coords == [] and found.leaks == []
    assert found.entrances_found == 1
    assert found.data == {"undeclared": [], "floor_missing": 0, "platform_missing": 0, "platform_blocked": 0}
    assert set(found.composition) == set(found.deviations) == set(spec.ores)
    assert found.composition["minecraft:stone"] == pytest.approx(0.6, abs=0.01)
    assert max(found.deviations.values()) < 0.01
    with pytest.raises(ValueError, match="padding"):
        mine_valid(region.sub(spec.geometry().outer), spec)
    with pytest.raises(ValueError, match="world"):
        mine_valid(region, MineSpec.from_dict({**MINE_SPEC, "world": "other"}))


def test_the_leaky_mine_names_the_hole(leaky_mine_region: Fixture) -> None:
    found = mine_valid(*leaky_mine_region)
    assert not found.ok and found.detail == "1 leaks; 1 undeclared opening cells"
    assert found.leaks == [(20, 3, 10)] and found.entrances_found == 2
    assert found.data["undeclared"] == [(19, 3, 10)] and found.coords == [(20, 3, 10), (19, 3, 10)]


def test_wrong_weights_fail_with_per_block_deviations(box_mine_region: Fixture) -> None:
    region, spec = box_mine_region
    found = mine_valid(region, MineSpec.from_dict({**MINE_SPEC, "ores": {"stone": 50, "coal_ore": 30, "iron_ore": 10, "gold_ore": 10}}))
    assert not found.ok and found.detail == "composition off"
    assert found.deviations["minecraft:stone"] == pytest.approx(0.098, abs=0.01)
    assert found.deviations["minecraft:gold_ore"] == 0.1 and found.deviations["minecraft:coal_ore"] < 0.01
    region.fill(Bounds((2, 2, 2), (17, 2, 17)), "minecraft:gravel")
    found = mine_valid(region, spec)
    assert not found.ok and found.deviations["minecraft:gravel"] == pytest.approx(1 / 6)
    stray = "256 interior cells neither air nor in ores [(2, 2, 2), (3, 2, 2)"
    assert mine_valid(region, spec, tolerance=0.2).detail.startswith(stray)
    layered = MineSpec.from_dict({**MINE_SPEC, "ore_layers": [{"y_from": 2, "y_to": 2, "ores": {"gravel": 1}}]})
    found = mine_valid(region, layered)
    assert found.detail.startswith(stray) and found.coords[0] == (2, 2, 2) and len(found.coords) == 20
    assert found.deviations["minecraft:gravel@2..2"] == 0.0 and "minecraft:gravel" not in found.deviations
    gravelly = MineSpec.from_dict({**MINE_SPEC, "ores": {**MINE_SPEC["ores"], "gravel": 20}})
    assert mine_valid(region, gravelly).ok
    assert found.composition["minecraft:gravel"] == pytest.approx(1 / 6)


def test_one_stray_interior_block_fails_at_any_tolerance(box_mine_region: Fixture) -> None:
    region, spec = box_mine_region
    region.set(5, 3, 6, "minecraft:torch")
    region.set(6, 3, 6, AIR)
    found = mine_valid(region, spec, tolerance=1.0)
    assert not found.ok and found.detail == "1 interior cells neither air nor in ores [(5, 3, 6)]"
    assert found.coords == [(5, 3, 6)]


def test_an_undeclared_opening_is_detected(box_mine_region: Fixture) -> None:
    region, spec = box_mine_region
    region.set(10, 9, 10, AIR)
    found = mine_valid(region, spec)
    assert not found.ok and found.detail == "1 undeclared opening cells" and found.leaks == []
    assert found.entrances_found == 2 and found.coords == [(10, 9, 10)]
    region.fill(Bounds((9, 2, 0), (11, 4, 1)), "minecraft:stone")
    found = mine_valid(region, spec)
    assert found.detail == "entrance not open; 1 undeclared opening cells" and found.entrances_found == 1


def test_a_mine_sealed_behind_its_doorway_is_not_open(box_mine_region: Fixture) -> None:
    box_mine_region[0].fill(Bounds((9, 2, 1), (11, 4, 1)), "minecraft:stone")
    assert mine_valid(*box_mine_region).detail == "entrance not open"


def test_a_missing_floor_block_is_reported(box_mine_region: Fixture) -> None:
    region, spec = box_mine_region
    region.set(5, 1, 6, AIR)
    found = mine_valid(region, spec)
    assert not found.ok and found.detail == "1 floor cells missing" and found.coords == [(5, 1, 6)]
    assert found.data["floor_missing"] == 1
    region.set(5, 1, 6, "minecraft:lava")
    assert mine_valid(region, spec).coords == [(5, 1, 6)]


def test_a_missing_exit_platform_block_is_reported(box_mine_region: Fixture) -> None:
    region, spec = box_mine_region
    region.set(10, 1, -3, AIR)
    found = mine_valid(region, spec)
    assert not found.ok and found.detail == "1 exit platform cells missing" and found.coords == [(10, 1, -3)]
    assert found.data["platform_missing"] == 1 and found.data["platform_blocked"] == 0


def test_a_block_placed_on_the_exit_platform_is_reported(box_mine_region: Fixture) -> None:
    region, spec = box_mine_region
    region.set(10, 2, -3, "minecraft:stone")
    found = mine_valid(region, spec)
    assert not found.ok and found.detail == "1 exit platform cells blocked above" and found.coords == [(10, 2, -3)]
    assert found.data["platform_blocked"] == 1 and found.data["platform_missing"] == 0


def test_an_undeclared_opening_overlapping_the_entrance_only_counts_the_extra_cells(box_mine_region: Fixture) -> None:
    region, spec = box_mine_region
    region.set(10, 5, 0, AIR)
    found = mine_valid(region, spec)
    assert not found.ok and found.detail == "1 undeclared opening cells" and found.entrances_found == 1
    assert found.data["undeclared"] == [(10, 5, 0)]
