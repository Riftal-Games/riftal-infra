import json
import re

import numpy as np
import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT
from designer.region import Region
from designer.verify import mine_valid, travel_time

SPEC_PATH = PROJECT_ROOT / "specs" / "mine_a.json"


@pytest.fixture
def spec() -> MineSpec:
    return MineSpec.from_dict(json.loads(SPEC_PATH.read_text(encoding="utf-8")))


@pytest.fixture
def palette() -> Palette:
    return Palette.load("mine_stone")


def _built_region(spec: MineSpec, palette: Palette):
    edits = build_mine(spec, palette)
    geo = spec.geometry()
    base = Region.empty(spec.world, geo.padding.union(geo.exit_platform))
    return edits, edits.to_region(base)


def _location(edits, name: str) -> tuple[int, int, int]:
    return tuple(next(l for l in edits.extras["locations"] if l["name"] == name)["pos"])


def _layered() -> dict:
    """The committed spec with one ore layer over its bottom three rows, which the committed spec has none of."""
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    data["ore_layers"] = [{"y_from": 40, "y_to": 42, "ores": {"stone": 50, "coal_ore": 30, "iron_ore": 15, "gold_ore": 5}}]
    return data


def test_committed_spec_pins_the_mine_a_fragment(spec: MineSpec) -> None:
    assert spec.name == "mine_a" and spec.world == "mine_a"
    assert spec.geometry().interior.to_json() == {"min": [-16, 40, -16], "max": [15, 50, 15]} and spec.floor_y == 40
    assert spec.ores == {"minecraft:stone": 1.0, "minecraft:coal_ore": 0.5} and spec.ore_layers == ()


def test_an_ore_layer_override_loads_and_places_only_inside_its_rows(palette: Palette) -> None:
    layered = MineSpec.from_dict(_layered())
    assert len(layered.ore_layers) == 1 and layered.ore_layers[0].ores["minecraft:gold_ore"] == 5.0
    gold_rows = {op.y for op in build_mine(layered, palette).ops if getattr(op, "block", "") == "minecraft:gold_ore"}
    assert gold_rows and gold_rows <= {40, 41, 42}


def test_to_region_passes_mine_valid(spec: MineSpec, palette: Palette) -> None:
    _, region = _built_region(spec, palette)
    found = mine_valid(region, spec)
    assert found.ok and found.detail == "mine valid", found.detail


def test_travel_time_from_spawn_to_exit_is_under_ten_seconds(spec: MineSpec, palette: Palette) -> None:
    edits, region = _built_region(spec, palette)
    spawn, exit_ = _location(edits, "mine_a_spawn"), _location(edits, "mine_a_exit")
    found = travel_time(region, spawn, exit_)
    assert found.ok and found.seconds < 10, found.detail


def test_build_mine_is_deterministic_by_seed(spec: MineSpec, palette: Palette) -> None:
    first, second = build_mine(spec, palette), build_mine(spec, palette)
    assert first.to_json() == second.to_json()


def test_a_different_seed_changes_the_ore_fill(spec: MineSpec, palette: Palette) -> None:
    other = MineSpec.from_dict({**json.loads(SPEC_PATH.read_text(encoding="utf-8")), "seed": spec.seed + 1})
    assert build_mine(spec, palette).to_json() != build_mine(other, palette).to_json()


def test_index_entries_cover_the_mine(spec: MineSpec, palette: Palette) -> None:
    edits = build_mine(spec, palette)
    names = {l["name"] for l in edits.extras["locations"]} | {r["name"] for r in edits.extras["regions"]}
    assert names == {
        "mine_a", "mine_a_interior", "mine_a_entrance", "mine_a_exit_platform",
        "mine_a_exit", "mine_a_spawn", "sell_npc_a", "rankup_npc_a",
    }


def test_reset_bounds_equal_the_interior(spec: MineSpec, palette: Palette) -> None:
    edits = build_mine(spec, palette)
    assert edits.extras["mine_reset"]["interior"] == spec.geometry().interior.to_json()
    assert edits.extras["mine_reset"]["reset_percent"] == spec.reset_percent == 60


def test_mine_spec_extra_round_trips_through_from_dict(spec: MineSpec, palette: Palette) -> None:
    edits = build_mine(spec, palette)
    rebuilt = MineSpec.from_dict(edits.extras["mine_spec"])
    assert rebuilt.geometry() == spec.geometry()


def test_sign_roles_carry_an_explicit_rotation_not_the_alias_default(spec: MineSpec, palette: Palette) -> None:
    edits = build_mine(spec, palette)
    sign_ops = [op for op in edits.ops if getattr(op, "block", "").startswith("minecraft:standing_sign[")]
    assert len(sign_ops) == 2 and all("ground_sign_direction=0" in op.block for op in sign_ops)


def test_hollow_fill_carves_the_interior_to_air(spec: MineSpec, palette: Palette) -> None:
    hollow = MineSpec.from_dict({**json.loads(SPEC_PATH.read_text(encoding="utf-8")), "fill": "hollow"})
    edits, region = _built_region(hollow, palette)
    geo = hollow.geometry()
    assert region.sub(geo.interior).counts() == {"minecraft:air": geo.interior.volume}


@pytest.mark.parametrize("field", ["origin", "size"])
def test_from_dict_rejects_a_fractional_coordinate(field: str) -> None:
    data = {**json.loads(SPEC_PATH.read_text(encoding="utf-8")), field: [-0.5, 20, 20]}
    with pytest.raises(ValueError, match="origin and size must be three integers"):
        MineSpec.from_dict(data)


def test_from_dict_rejects_a_fractional_floor_y() -> None:
    data = {**json.loads(SPEC_PATH.read_text(encoding="utf-8")), "floor_y": -0.5}
    with pytest.raises(ValueError, match="floor_y must be an integer"):
        MineSpec.from_dict(data)


@pytest.mark.parametrize("field", ["y_from", "y_to"])
def test_from_dict_rejects_a_fractional_ore_layer_bound(field: str) -> None:
    data = _layered()
    data["ore_layers"][0][field] = -0.5
    with pytest.raises(ValueError, match="y_from and y_to must be integers"):
        MineSpec.from_dict(data)


@pytest.mark.parametrize("path, value, message", [
    (("wall_thickness",), 2.5, r"wall_thickness must be an integer, got 2\.5"),
    (("entrance", "width"), 2.5, r"entrance width must be an integer, got 2\.5"),
    (("entrance", "height"), 2.5, r"entrance height must be an integer, got 2\.5"),
    (("entrance", "offset"), 0.5, r"entrance offset must be an integer, got 0\.5"),
    (("exit_path", "length"), 2.5, r"exit_path length must be an integer, got 2\.5"),
    (("exit_path", "width"), 2.5, r"exit_path width must be an integer, got 2\.5"),
    (("seed",), 2.5, r"seed must be an integer, got 2\.5"),
    (("lights_every",), 2.5, r"lights_every must be an integer, got 2\.5"),
    (("reset_percent",), 60.5, r"reset_percent must be an integer, got 60\.5"),
])
def test_from_dict_rejects_a_fractional_size_or_count(path: tuple[str, ...], value: float, message: str) -> None:
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    *parents, key = path
    target = data
    for p in parents:
        target = target[p]
    target[key] = value
    with pytest.raises(ValueError, match=f"^{message}$"):
        MineSpec.from_dict(data)


def _lantern_positions(region: Region) -> set[tuple[int, int, int]]:
    lanterns = [i for i, name in enumerate(region.palette) if name.startswith("minecraft:lantern")]
    ys, zs, xs = np.nonzero(np.isin(region.blocks, lanterns))
    x0, y0, z0 = region.bounds.min
    return {(x0 + int(x), y0 + int(y), z0 + int(z)) for x, y, z in zip(xs, ys, zs)}


# The platform's last row holds the sell sign on the lit edge, so a length that is a
# multiple of lights_every lights the row before it instead; a one-row platform has no
# row to spare.
@pytest.mark.parametrize("length, every, distances", [
    (6, 4, [4]), (13, 4, [4, 8, 12]), (11, 3, [3, 6, 9]),
    (8, 4, [4, 7]), (12, 3, [3, 6, 9, 11]), (4, 1, [1, 2, 3]), (1, 1, []),
])
def test_exit_platform_lights_sit_every_lights_every_blocks_along_its_edge(
    length: int, every: int, distances: list[int], palette: Palette
) -> None:
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    data["exit_path"]["length"], data["lights_every"] = length, every
    lit = MineSpec.from_dict(data)
    edits, region = _built_region(lit, palette)
    geo = lit.geometry()
    x, face = geo.exit_platform.min[0], geo.outer.max[2]
    assert _lantern_positions(region) == {(x, lit.floor_y, face + d) for d in distances}
    assert {region.get(x, lit.floor_y, face + d) for d in distances} <= {"minecraft:lantern[hanging=false]"}
    signs = {region.get(*_location(edits, name)) for name in ("sell_npc_a", "rankup_npc_a")}
    assert len(signs) == 1 and signs.pop().startswith("minecraft:standing_sign[")


# Read from the ops, since a later sign op paints over a light on the sign row and a repeated op paints nothing new.
@pytest.mark.parametrize("width", [3, 4, 5])
@pytest.mark.parametrize("length, every, distances", [(8, 4, [4, 7]), (12, 3, [3, 6, 9, 11]), (4, 1, [1, 2, 3]), (1, 1, [])])
def test_exit_platform_light_ops_are_one_per_light_and_none_on_the_sign_row(
    width: int, length: int, every: int, distances: list[int], palette: Palette
) -> None:
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    data["exit_path"]["width"], data["exit_path"]["length"], data["lights_every"] = width, length, every
    lit = MineSpec.from_dict(data)
    geo = lit.geometry()
    x, face = geo.exit_platform.min[0], geo.outer.max[2]
    lights = [(op.x, op.y, op.z) for op in build_mine(lit, palette).ops if getattr(op, "block", "").startswith("minecraft:lantern")]
    assert sorted(lights, key=lambda p: p[2]) == [(x, lit.floor_y, face + d) for d in distances]
    assert all(z != face + length for _, _, z in lights)


@pytest.mark.parametrize("width", [1, 2])
def test_from_dict_refuses_an_exit_path_narrower_than_3(width: int) -> None:
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    data["exit_path"]["width"] = width
    with pytest.raises(ValueError, match=f"^exit_path width must be at least 3 to hold both signs beside the walking line, got {width}$"):
        MineSpec.from_dict(data)


@pytest.mark.parametrize("width", [3, 4, 5])
def test_signs_sit_on_the_platform_and_lights_off_the_walking_line(width: int, palette: Palette) -> None:
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    data["exit_path"]["width"] = width
    wide = MineSpec.from_dict(data)
    edits, region = _built_region(wide, palette)
    platform = wide.geometry().exit_platform
    for name in ("sell_npc_a", "rankup_npc_a"):
        x, y, z = _location(edits, name)
        assert platform.min[0] <= x <= platform.max[0] and platform.min[2] <= z <= platform.max[2] and y == platform.min[1] + 1
    walking_x = _location(edits, "mine_a_spawn")[0]
    lanterns = _lantern_positions(region)
    assert lanterns and all(x != walking_x for x, _, _ in lanterns)


def _outer_tags(spec: MineSpec, palette: Palette) -> list[str]:
    return next(r for r in build_mine(spec, palette).extras["regions"] if r["name"] == spec.name)["tags"]


def test_a_spec_without_safe_zone_builds_a_safe_mine(palette: Palette) -> None:
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    del data["safe_zone"]
    assert _outer_tags(MineSpec.from_dict(data), palette) == ["mine", "safe_zone"]


@pytest.mark.parametrize("name", ["mine_a", "mine_b", "mine_c", "lumber"])
def test_committed_specs_build_safe_mines(name: str, palette: Palette) -> None:
    spec = MineSpec.from_dict(json.loads((PROJECT_ROOT / "specs" / f"{name}.json").read_text(encoding="utf-8")))
    assert _outer_tags(spec, palette) == ["mine", "safe_zone"]


def test_safe_zone_false_leaves_only_the_mine_tag(palette: Palette) -> None:
    contested = MineSpec.from_dict({**json.loads(SPEC_PATH.read_text(encoding="utf-8")), "safe_zone": False})
    edits = build_mine(contested, palette)
    assert _outer_tags(contested, palette) == ["mine"]
    assert MineSpec.from_dict(edits.extras["mine_spec"]).safe_zone is False
    assert all("safe_zone" not in r["tags"] for r in edits.extras["regions"])


@pytest.mark.parametrize("value", ["false", 0, 1, None, ["safe_zone"]])
def test_from_dict_rejects_a_safe_zone_that_is_not_a_boolean(value: object) -> None:
    data = {**json.loads(SPEC_PATH.read_text(encoding="utf-8")), "safe_zone": value}
    with pytest.raises(ValueError, match=f"^safe_zone must be true or false, got {re.escape(repr(value))}$"):
        MineSpec.from_dict(data)
