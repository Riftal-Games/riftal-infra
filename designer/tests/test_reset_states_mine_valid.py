import json

import pytest

from designer.blocks import AIR
from designer.builders.mine_spec import MineSpec
from designer.config import PROJECT_ROOT
from designer.region import Region
from designer.verify import mine_valid


def _lumber_filled_with(block: str, ores: dict[str, float]) -> tuple[Region, MineSpec]:
    raw = json.loads((PROJECT_ROOT / "specs" / "lumber.json").read_text(encoding="utf-8"))
    spec = MineSpec.from_dict({**raw, "ores": ores})
    geo = spec.geometry()
    region = Region.empty(spec.world, geo.padding.union(geo.exit_platform))
    region.fill(geo.outer, "minecraft:stone")
    region.fill(geo.interior, block)
    region.fill(geo.entrance, AIR)
    region.fill(geo.exit_platform, "minecraft:stone")
    return region, spec


# A key spelling the block's whole state is also the block's canonical name, so the
# fallback in _as_ores must not let it through when that state is not the reset's.
@pytest.mark.parametrize(("block", "ores"), [
    ("minecraft:oak_log[pillar_axis=x]", {"minecraft:oak_log[pillar_axis=x]": 1.0}),
    ("minecraft:quartz_ore", {"minecraft:quartz_ore": 1.0}),
])
def test_mine_valid_fails_a_mine_the_reset_would_rewrite(block: str, ores: dict[str, float]) -> None:
    found = mine_valid(*_lumber_filled_with(block, ores))
    assert not found.ok, found.detail
    assert "interior cells neither air nor in ores" in found.detail


def test_mine_valid_passes_the_reset_state_of_a_stated_key() -> None:
    found = mine_valid(*_lumber_filled_with("minecraft:oak_log[pillar_axis=y]", {"minecraft:oak_log[pillar_axis=y]": 1.0}))
    assert found.ok, found.detail
