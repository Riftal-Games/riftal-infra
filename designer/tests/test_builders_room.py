import numpy as np
import pytest

from designer.blocks import BlockClass
from designer.builders.base import Palette
from designer.builders.room import RoomSpec, build_room


@pytest.fixture
def palette() -> Palette:
    return Palette.load("mine_stone")


def _spec(**over) -> RoomSpec:
    data = {
        "name": "cell", "world": "design", "origin": [0, 0, 0], "size": [7, 4, 7],
        "wall_thickness": 1, "door": {"side": "south", "width": 2, "height": 2}, "lights_every": 3,
    }
    data.update(over)
    return RoomSpec.from_dict(data)


def test_from_dict_rejects_a_missing_field() -> None:
    with pytest.raises(ValueError, match=r"missing \['door'\]"):
        RoomSpec.from_dict({"name": "c", "world": "design", "origin": [0, 0, 0], "size": [7, 4, 7]})


@pytest.mark.parametrize("over, match", [
    ({"size": [2, 2, 2], "wall_thickness": 1}, "does not hold an interior"),
    ({"door": {"side": "south", "width": 9, "height": 2}}, "does not fit the wall"),
])
def test_from_dict_rejects_bad_dimensions(over: dict, match: str) -> None:
    with pytest.raises(ValueError, match=match):
        _spec(**over)


def test_region_and_door_location_are_indexed_and_edits_apply_onto_their_own_bounds(palette: Palette) -> None:
    edits = build_room(_spec(), palette)
    [region], [location] = edits.extras["regions"], edits.extras["locations"]
    assert region["name"] == "cell" and (region["min"], region["max"]) == ([0, 0, 0], [6, 3, 6])
    assert location["name"] == "cell_door" and location["pos"][2] == 7
    region_built = edits.to_region()
    assert (region_built.bounds.min, region_built.bounds.max) == (edits.bounds.min, edits.bounds.max)


def test_lights_form_a_grid_across_the_ceiling(palette: Palette) -> None:
    spec = _spec(lights_every=3)
    geo = spec.geometry()
    light = palette.block("light")
    lights = [op for op in build_room(spec, palette).ops if getattr(op, "block", "").startswith(light)]
    xs = range(geo.interior.min[0], geo.interior.max[0] + 1, spec.lights_every)
    zs = range(geo.interior.min[2], geo.interior.max[2] + 1, spec.lights_every)
    assert len(lights) == len(list(xs)) * len(list(zs))
    assert all(op.y == geo.interior.max[1] for op in lights)


def test_door_is_the_only_opening(palette: Palette) -> None:
    spec = _spec()
    geo = spec.geometry()
    region = build_room(spec, palette).to_region()
    classes = region.classes()
    surface = np.zeros(classes.shape, dtype=bool)
    for axis in range(3):
        surface[tuple(0 if a == axis else slice(None) for a in range(3))] = True
        surface[tuple(-1 if a == axis else slice(None) for a in range(3))] = True
    opening = np.zeros(classes.shape, dtype=bool)
    opening[region.bounds.slices(geo.door)] = True
    passable = (classes == BlockClass.AIR) | (classes == BlockClass.PASSABLE)
    assert passable[opening].all()
    assert not (surface & passable & ~opening).any()


def test_build_room_is_deterministic(palette: Palette) -> None:
    spec = _spec()
    assert build_room(spec, palette).to_json() == build_room(spec, palette).to_json()


@pytest.mark.parametrize("field", ["origin", "size"])
def test_from_dict_rejects_a_fractional_coordinate(field: str) -> None:
    with pytest.raises(ValueError, match="origin and size must be three integers"):
        _spec(**{field: [-0.5, 4, 7]})
