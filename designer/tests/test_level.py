import json
from pathlib import Path

import pytest

from designer.bridge import Bridge
from designer.level import LevelError, Saved, build_level, content_sha256, pregen_bounds
from designer.region import Bounds, Bounds2D, Region, fetch_region
from designer.world_index import Location, WorldEntry, WorldIndex
from tests.conftest import SMALL_MINE_SPEC, STONE_PALETTES
from tests.fake_bridge import FakeBridge, FakeWorld

RECIPE = {
    "generator": "normal", "seed": 7, "bounds": {"min": [0, 0, 0], "max": [15, 70, 15]},
    "steps": [{"build": "mine", "spec": "specs/zt.json", "palette": "test_stone"}],
}
SAVED = Saved("sha256:image", "bridge-commit", "toolkit-commit", 4096)


def _index(generator: str = "normal", seed: int = 7, listed: bool = True) -> WorldIndex:
    worlds = [WorldEntry("zt", generator, seed, "lumber")] if listed else []
    return WorldIndex(default_world="zt", worlds=worlds, locations=[Location("zt_spawn", "zt", (40, 64, 40))])


@pytest.fixture
def root(tmp_path: Path, fake: FakeBridge, monkeypatch: pytest.MonkeyPatch) -> Path:
    for target in ("designer.builders.base.load_palettes", "designer.level.load_palettes"):
        monkeypatch.setattr(target, lambda: STONE_PALETTES)
    fake.worlds["zt"] = FakeWorld()
    (tmp_path / "levels").mkdir()
    (tmp_path / "specs").mkdir()
    (tmp_path / "levels" / "zt.json").write_text(json.dumps(RECIPE), encoding="utf-8")
    (tmp_path / "specs" / "zt.json").write_text(json.dumps({**SMALL_MINE_SPEC, "world": "zt"}), encoding="utf-8")
    (tmp_path / "checks.yaml").write_text("version: 1\nchecks:\n  - check: warp_safe\n    at: zt_spawn\n", encoding="utf-8")
    return tmp_path


def _build(bridge: Bridge, root: Path, zone: str = "zt", index: WorldIndex | None = None, calls: list[str] | None = None) -> Path:
    def after_stop() -> Saved:
        if calls is not None:
            calls.append("after_stop")
        return SAVED

    return build_level(bridge, zone, after_stop, root=root, index=index or _index(), checks_path=root / "checks.yaml")


def test_build_writes_the_lock(fake: FakeBridge, bridge: Bridge, root: Path) -> None:
    lock = json.loads(_build(bridge, root).read_text(encoding="utf-8"))
    pregen = [r["args"]["bounds"] for r in fake.requests if r["op"] == "pregen"]
    assert pregen == [{"min": [-16, -16], "max": [31, 31]}]
    assert lock["chunks"] == len(fake.pregenerated["zt"]) == 9
    assert fake.worlds["zt"].edits, "the recipe's mine step never reached the bridge"
    region = fetch_region(bridge, "zt", Bounds((0, 0, 0), (15, 70, 15)))
    assert lock["content_sha256"] == content_sha256(region)
    assert sorted(lock["inputs"]) == ["levels/zt.json", "palette:test_stone", "specs/zt.json"]
    assert (lock["core_image"], lock["size_bytes"], lock["seed"]) == ("sha256:image", 4096, 7)


def test_scan_finding_refuses_and_writes_no_lock(fake: FakeBridge, bridge: Bridge, root: Path) -> None:
    fake.scan_findings = [{"kind": "tile", "chunk": [0, 0], "pos": [1, 64, 1], "save_id": "Chest"}]
    calls: list[str] = []
    with pytest.raises(LevelError, match="1 item or entity finding"):
        _build(bridge, root, calls=calls)
    assert calls == []
    assert not (root / "levels" / "zt.lock.json").exists()


def test_failing_check_refuses(bridge: Bridge, root: Path) -> None:
    index = _index()
    index.locations = [Location("zt_spawn", "zt", (40, 10, 40))]
    with pytest.raises(LevelError, match="warp_safe_zt_spawn"):
        _build(bridge, root, index=index)
    assert not (root / "levels" / "zt.lock.json").exists()


@pytest.mark.parametrize("zone", ["old_world", "player_1", "backup", "Lumber", "a-b"])
def test_refused_names_make_no_call(fake: FakeBridge, bridge: Bridge, root: Path, zone: str) -> None:
    (root / "levels" / f"{zone}.json").write_text(json.dumps(RECIPE), encoding="utf-8")
    with pytest.raises(LevelError, match="contains|must match"):
        _build(bridge, root, zone)
    assert fake.requests == []


@pytest.mark.parametrize(("index", "match"), [
    pytest.param(_index(seed=8), "generator and seed", id="seed"),
    pytest.param(_index(generator="flat"), "generator and seed", id="generator"),
    pytest.param(_index(listed=False), "has no world 'zt'", id="missing"),
])
def test_index_must_agree_before_any_call(fake: FakeBridge, bridge: Bridge, root: Path, index: WorldIndex, match: str) -> None:
    with pytest.raises(LevelError, match=match):
        _build(bridge, root, index=index)
    assert fake.requests == []


def test_step_input_outside_the_root_is_refused(fake: FakeBridge, bridge: Bridge, root: Path) -> None:
    recipe = {**RECIPE, "steps": [{"build": "mine", "spec": "../zt.json", "palette": "test_stone"}]}
    (root.parent / "zt.json").write_text("{}", encoding="utf-8")
    (root / "levels" / "zt.json").write_text(json.dumps(recipe), encoding="utf-8")
    with pytest.raises(LevelError, match="not a file under"):
        _build(bridge, root)
    assert fake.requests == []


def test_pregen_bounds_add_a_chunk_on_each_side_of_negative_bounds() -> None:
    assert pregen_bounds(Bounds((-10, 38, -10), (10, 52, 10))) == Bounds2D((-32, -32), (31, 31))


def test_content_sha256_ignores_palette_order_and_sees_every_block_and_file() -> None:
    box = Bounds((0, 0, 0), (1, 1, 1))
    a = Region.empty("zt", box)
    a.fill(Bounds((0, 0, 0), (1, 0, 1)), "minecraft:stone")
    a.fill(Bounds((0, 1, 0), (0, 1, 0)), "minecraft:dirt")
    b = Region.empty("zt", box)
    b.fill(Bounds((0, 1, 0), (0, 1, 0)), "minecraft:dirt")
    b.fill(Bounds((0, 0, 0), (1, 0, 1)), "minecraft:stone")
    assert a.palette != b.palette
    assert content_sha256(a) == content_sha256(b)
    b.fill(Bounds((1, 1, 1), (1, 1, 1)), "minecraft:stone")
    assert content_sha256(a) != content_sha256(b)
    assert content_sha256(a, npcs=[]) != content_sha256(a) != content_sha256(a, texts=[])
