"""ADR 014 proof 11: ``build_level`` itself, with the committed ``checks.yaml`` and mine specs, on the fake bridge."""

import json
import shutil
from pathlib import Path

import pytest
import yaml

from designer.bridge import Bridge
from designer.builders import BUILDERS
from designer.checks import DEFAULT_PATH as CHECKS
from designer.config import PROJECT_ROOT
from designer.edits import EditList, SetBlock
from designer.level import LevelError, Saved, build_level
from tests.conftest import STONE_PALETTES
from tests.fake_bridge import ALLOWED_BLOCKS, FakeBridge, FakeWorld

BOUNDS = {"min": [-20, 36, -20], "max": [20, 56, 26]}
MINES = "worlds:\n  lumber: worlds/lumber.json\n  mine_a: worlds/mine_a.json\n  mine_b: worlds/mine_b.json\n  mine_c: worlds/mine_c.json\n"
MINE_A_INTERIOR_CELL = [0, 45, 0]
LOG = "minecraft:oak_log[pillar_axis=y]"
ZONES = ["mine_a", "mine_b", "mine_c", "lumber"]
# DesignBridge reads a block back by its Bedrock name with its states, whatever alias or states the write named.
READ_BACK = {"minecraft:oak_log": LOG, "minecraft:lapis_lazuli_ore": "minecraft:lapis_ore"}


def _poke(spec: dict, palette: object, fetch: object) -> EditList:
    return EditList(spec["world"], [SetBlock(*spec["at"], spec["block"])])


@pytest.fixture
def root(tmp_path: Path, fake: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> Path:
    for target in ("designer.builders.base.load_palettes", "designer.level.load_palettes"):
        monkeypatch.setattr(target, lambda: STONE_PALETTES)
    # The mine builder hangs its lights with a state, and test_stone makes every light stone.
    extra = {"minecraft:coal_ore", "minecraft:iron_ore", "minecraft:copper_ore", "minecraft:lapis_ore"}
    extra |= {LOG, "minecraft:torch", "minecraft:chorus_flower", "minecraft:stone[hanging=false]"}
    monkeypatch.setattr("tests.fake_bridge.ALLOWED_BLOCKS", ALLOWED_BLOCKS | extra)
    index_of = FakeWorld.index_of
    monkeypatch.setattr(FakeWorld, "index_of", lambda world, name, where="block": index_of(world, READ_BACK.get(name, name), where))
    monkeypatch.setitem(BUILDERS, "poke", _poke)
    monkeypatch.setattr("designer.checks.PROJECT_ROOT", tmp_path)
    shutil.copytree(PROJECT_ROOT / "specs", tmp_path / "specs")
    (tmp_path / "levels").mkdir()
    for zone in ZONES:
        # Terrain away from the build, so the committed specs are read on air and nothing but what they write.
        fake.worlds[zone] = FakeWorld(extent=((100, 100), (101, 101)))
        _recipe(tmp_path, zone)
    (tmp_path / "mines.yml").write_text(MINES, encoding="utf-8")
    return tmp_path


def _recipe(root: Path, zone: str, *poke: dict) -> None:
    steps = [{"build": "mine", "spec": f"specs/{zone}.json", "palette": "test_stone"}]
    for n, change in enumerate(poke):
        (root / "specs" / f"poke{n}.json").write_text(json.dumps({"world": zone, **change}), encoding="utf-8")
        steps.append({"build": "poke", "spec": f"specs/poke{n}.json", "palette": "test_stone"})
    recipe = {"generator": "normal", "seed": 20260907, "bounds": BOUNDS, "steps": steps}
    (root / "levels" / f"{zone}.json").write_text(json.dumps(recipe), encoding="utf-8")


def _build(bridge: Bridge, root: Path, zone: str, checks: Path = CHECKS, mines: Path | None = None) -> Path:
    saved = Saved("sha256:image", "bridge-commit", "toolkit-commit", 4096)
    return build_level(bridge, zone, lambda: saved, root=root, checks_path=checks, mines_config=mines or root / "mines.yml")


def _refused(bridge: Bridge, root: Path, zone: str, match: str, **kwargs: Path) -> None:
    with pytest.raises(LevelError, match=match):
        _build(bridge, root, zone, **kwargs)
    assert not (root / "levels" / f"{zone}.lock.json").exists()


@pytest.mark.parametrize("zone", ZONES)
def test_one_mine_step_builds_and_writes_a_lock(bridge: Bridge, root: Path, zone: str) -> None:
    assert json.loads(_build(bridge, root, zone).read_text(encoding="utf-8"))["zone"] == zone


def test_a_torch_in_the_interior_refuses_naming_the_entry_and_cell(bridge: Bridge, root: Path) -> None:
    _recipe(root, "mine_a", {"at": MINE_A_INTERIOR_CELL, "block": "minecraft:torch"})
    _refused(bridge, root, "mine_a", r"mine_valid_mine_a: 1 interior cells neither air nor in ores \[\(0, 45, 0\)\]")


def test_a_layer_ore_absent_from_ores_refuses(bridge: Bridge, root: Path) -> None:
    spec = json.loads((root / "specs" / "mine_a.json").read_text(encoding="utf-8"))
    spec["ore_layers"] = [{"y_from": 45, "y_to": 45, "ores": {"minecraft:iron_ore": 1}}]
    (root / "specs" / "mine_a.json").write_text(json.dumps(spec), encoding="utf-8")
    _refused(bridge, root, "mine_a", r"mine_valid_mine_a: 1024 interior cells neither air nor in ores \[\(-16, 45, -16\)")


# An alias reads back under another name, and it has no reset state, so it is refused before any request.
def test_an_ore_named_by_an_alias_refuses_since_it_has_no_reset_state(fake: FakeBridge, bridge: Bridge, root: Path) -> None:
    spec = json.loads((root / "specs" / "mine_c.json").read_text(encoding="utf-8"))
    spec["ores"] = {"minecraft:iron_ore": 1.0, "minecraft:lapis_lazuli_ore": 0.4}
    (root / "specs" / "mine_c.json").write_text(json.dumps(spec), encoding="utf-8")
    _refused(bridge, root, "mine_c", r"specs/mine_c\.json names \['minecraft:lapis_lazuli_ore'\], which have no reset state")
    assert fake.requests == []


def test_a_chorus_flower_outside_every_interior_refuses(bridge: Bridge, root: Path) -> None:
    _recipe(root, "lumber", {"at": [19, 54, 19], "block": "minecraft:chorus_flower"})
    _refused(bridge, root, "lumber", r"1 chorus flower\(s\) outside every mine interior, first at \(19, 54, 19\)")


@pytest.mark.parametrize("change", [
    pytest.param({"zone": None}, id="untagged"),
    pytest.param({"spec": "specs/mine_a.json"}, id="spec-not-built"),
])
def test_a_mines_world_without_its_zone_tagged_entry_refuses_before_any_request(
    fake: FakeBridge, bridge: Bridge, root: Path, change: dict,
) -> None:
    data = yaml.safe_load(CHECKS.read_text(encoding="utf-8"))
    entry = next(c for c in data["checks"] if c.get("zone") == "lumber" and c["check"] == "mine_valid")
    entry.update(change)
    (root / "checks.yaml").write_text(yaml.safe_dump({**data, "checks": [{k: v for k, v in c.items() if v is not None} for c in data["checks"]]}), encoding="utf-8")
    _refused(bridge, root, "lumber", "mines.yml lists 'lumber', but checks.yaml has no mine_valid with zone 'lumber'", checks=root / "checks.yaml")
    assert fake.requests == []


@pytest.mark.parametrize("zone", ["mine_a", "lumber"])
def test_no_mines_config_refuses_every_zone_before_any_request(
    fake: FakeBridge, bridge: Bridge, root: Path, zone: str, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("RIFTAL_GAME_DIR", str(root / "no_game"))
    with pytest.raises(LevelError, match=r"cannot read the mines world list .*no_game.*config\.yml"):
        build_level(bridge, zone, lambda: pytest.fail("after_stop"), root=root, checks_path=CHECKS)
    (root / "mines.yml").write_text("worlds: [mine_a]\n", encoding="utf-8")
    _refused(bridge, root, zone, "worlds is a list, not a mapping")
    assert fake.requests == []
