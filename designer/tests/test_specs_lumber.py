import json

import pytest

from designer.builders.base import Palette
from designer.builders.mine import build_mine
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT
from designer.region import Region
from designer.verify import mine_valid

SPEC_PATH = PROJECT_ROOT / "specs" / "lumber.json"


@pytest.fixture
def raw() -> dict:
    return json.loads(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture
def spec(raw: dict) -> MineSpec:
    return MineSpec.from_dict(raw)


@pytest.fixture
def palette() -> Palette:
    return Palette.load("mine_stone")


def test_committed_lumber_spec_loads(spec: MineSpec) -> None:
    assert spec.name == "lumber" and spec.world == "lumber"
    assert spec.ores == {"minecraft:oak_log": 1.0}


def test_lumber_spec_passes_mine_valid(spec: MineSpec, palette: Palette) -> None:
    edits = build_mine(spec, palette)
    geo = spec.geometry()
    base = Region.empty(spec.world, geo.padding.union(geo.exit_platform))
    region = edits.to_region(base)
    found = mine_valid(region, spec)
    assert found.ok and found.detail == "mine valid", found.detail


def test_lumber_spec_with_a_zeroed_ore_weight_fails_validation(raw: dict) -> None:
    broken = {**raw, "ores": {"minecraft:oak_log": 0.0}}
    with pytest.raises(ValueError, match="positive weight"):
        MineSpec.from_dict(broken)


def test_lumber_spec_with_ores_deleted_fails_validation(raw: dict) -> None:
    broken = dict(raw)
    del broken["ores"]
    with pytest.raises(ValueError, match="missing"):
        MineSpec.from_dict(broken)
