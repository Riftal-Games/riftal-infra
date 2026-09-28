import json

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


def test_committed_spec_loads_and_places_the_ore_layer_override(spec: MineSpec) -> None:
    assert spec.name == "mine_a" and spec.world == "mine_a"
    assert len(spec.ore_layers) == 1 and spec.ore_layers[0].ores["minecraft:gold_ore"] == 5.0


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
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    data["ore_layers"][0][field] = -0.5
    with pytest.raises(ValueError, match="y_from and y_to must be integers"):
        MineSpec.from_dict(data)
