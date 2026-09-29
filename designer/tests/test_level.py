import json
from dataclasses import replace
from pathlib import Path
from typing import Any

import pytest
import yaml

from designer import world_index
from designer.bridge import Bridge
from designer.builders import BUILDERS
from designer.builders.base import Palette
from designer.level import LevelError, Saved, build_level, content_sha256, pregen_bounds
from designer.region import Bounds, Bounds2D, Region, fetch_region
from designer.world_index import Location, NamedRegion, WorldEntry, WorldIndex
from tests.conftest import SMALL_MINE_NAMES, SMALL_MINE_SPEC, STONE_PALETTES
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
    (tmp_path / "checks.yaml").write_text("version: 1\nchecks:\n  - check: warp_safe\n    zone: zt\n    at: zt_spawn\n", encoding="utf-8")
    (tmp_path / "mines.yml").write_text("worlds:\n  mine_x: worlds/mine_x.json\n", encoding="utf-8")
    return tmp_path


def _build(bridge: Bridge, root: Path, zone: str = "zt", index: WorldIndex | None = None, calls: list[str] | None = None) -> Path:
    def after_stop() -> Saved:
        if calls is not None:
            calls.append("after_stop")
        return SAVED

    return build_level(
        bridge, zone, after_stop, root=root, index=index or _index(), checks_path=root / "checks.yaml", mines_config=root / "mines.yml",
    )


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


def test_unknown_builder_refuses_before_any_call(fake: FakeBridge, bridge: Bridge, root: Path) -> None:
    recipe = {**RECIPE, "steps": [{"build": "moat", "spec": "specs/zt.json", "palette": "test_stone"}]}
    (root / "levels" / "zt.json").write_text(json.dumps(recipe), encoding="utf-8")
    with pytest.raises(LevelError, match="no builder 'moat'"):
        _build(bridge, root)
    assert fake.requests == []


def test_step_writing_another_world_refuses(fake: FakeBridge, bridge: Bridge, root: Path) -> None:
    fake.worlds["zo"] = FakeWorld()
    (root / "specs" / "zt.json").write_text(json.dumps({**SMALL_MINE_SPEC, "world": "zo"}), encoding="utf-8")
    with pytest.raises(LevelError, match="writes world 'zo'"):
        _build(bridge, root)
    assert not fake.worlds["zo"].edits and not (root / "levels" / "zt.lock.json").exists()


def test_failed_step_refuses(fake: FakeBridge, bridge: Bridge, root: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pregen = fake.op_pregen

    def pregen_then_fail(args: dict) -> dict:
        reply = pregen(args)
        fake.fail_next_job = "disk full"
        return reply

    monkeypatch.setattr(fake, "op_pregen", pregen_then_fail)
    with pytest.raises(LevelError, match="step 0 .* failed: .*disk full"):
        _build(bridge, root)
    assert not (root / "levels" / "zt.lock.json").exists()


def _checks(root: Path, *entries: dict) -> None:
    (root / "checks.yaml").write_text(yaml.safe_dump({"version": 1, "checks": list(entries)}), encoding="utf-8")


ZT_SPAWN = {"check": "warp_safe", "zone": "zt", "at": "zt_spawn"}


@pytest.mark.parametrize(("entry", "match"), [
    pytest.param({"check": "warp_safe", "at": "zt_spawn"}, "no check with zone 'zt'", id="none-scoped"),
    pytest.param({**ZT_SPAWN, "at": "zt_spwan"}, r"resolves: \['warp_safe_zt_spwan'\]", id="unresolved"),
    pytest.param({**ZT_SPAWN, "at": "zo_spawn"}, "warp_safe_zo_spawn reads 'zo'", id="elsewhere"),
])
def test_zone_checks_must_exist_resolve_and_read_the_zone(bridge: Bridge, root: Path, entry: dict, match: str) -> None:
    _checks(root, entry)
    index = _index()
    index.locations.append(Location("zo_spawn", "zo", (40, 64, 40)))
    with pytest.raises(LevelError, match=match):
        _build(bridge, root, index=index)
    assert not (root / "levels" / "zt.lock.json").exists()


def _step_entry(name: str) -> Location | NamedRegion:
    extras = BUILDERS["mine"]({**SMALL_MINE_SPEC, "world": "zt"}, Palette.load("test_stone"), None).extras
    entries = [*map(Location.from_json, extras["locations"]), *map(NamedRegion.from_json, extras["regions"])]
    return next(e for e in entries if e.name == name)


def _step_spawn() -> Location:
    spawn = _step_entry("tbox_spawn")
    assert isinstance(spawn, Location)
    return spawn


def test_zone_checks_resolve_names_the_steps_made(bridge: Bridge, root: Path) -> None:
    _checks(root, {"check": "region_inside", "zone": "zt", "inner": "tbox_interior", "outer": "tbox"},
            {"check": "entity_clear", "zone": "zt", "at": "tbox_spawn"})
    index = _index()
    committed = _step_spawn()
    index.locations.append(committed)
    assert _build(bridge, root, index=index).exists()
    assert index.resolve("tbox_spawn") is committed
    assert not (SMALL_MINE_NAMES - {"tbox_spawn"}) & index.names().keys(), "the build registered into the caller's index"


@pytest.mark.parametrize(("name", "change", "match"), [
    pytest.param("tbox_spawn", lambda s: replace(s, pos=(40, 10, 40)), r"pos \[3, 1, -2\] \(world_index.json \[40, 10, 40\]\)", id="pos"),
    pytest.param("tbox_spawn", lambda s: replace(s, world="zo"), "world zt .world_index.json zo.", id="world"),
    pytest.param("tbox_spawn", lambda s: replace(s, yaw=s.yaw + 45), r"yaw \S+ \(world_index.json \S+\)", id="yaw"),
    pytest.param("tbox_spawn", lambda s: replace(s, pitch=30), r"pitch 0 \(world_index.json 30\)", id="pitch"),
    pytest.param("sell_npc_tbox", lambda s: replace(s, tags=["npc"]), r"tags \['npc', 'sell'\] \(world_index.json \['npc'\]\)", id="location-tags"),
    pytest.param("sell_npc_tbox", lambda s: replace(s, tags=[*s.tags, "sell"]), r"tags \['npc', 'sell'\] \(world_index.json \['npc', 'sell', 'sell'\]\)", id="duplicate-tag"),
    pytest.param("tbox", lambda s: replace(s, world="zo"), "world zt .world_index.json zo.", id="region-world"),
    pytest.param("tbox", lambda s: replace(s, min=(s.min[0] - 1, *s.min[1:])), r"min \[.*\] \(world_index.json \[.*\]\)", id="min"),
    pytest.param("tbox", lambda s: replace(s, max=(*s.max[:2], s.max[2] + 1)), r"max \[.*\] \(world_index.json \[.*\]\)", id="max"),
    pytest.param("tbox_entrance", lambda s: replace(s, tags=["mine", "spawn"]), r"tags \['mine', 'walkway'\] \(world_index.json \['mine', 'spawn'\]\)", id="region-tags"),
    pytest.param("tbox", lambda s: replace(s, meta={**s.meta, "resets": "never"}), r"meta .* \(world_index.json .*'resets': 'never'", id="meta"),
    pytest.param("tbox_spawn", lambda s: NamedRegion(s.name, s.world, s.pos, s.pos), "Location in the step, a NamedRegion", id="kind"),
])
def test_a_step_differing_from_a_committed_entry_refuses(fake: FakeBridge, bridge: Bridge, root: Path, name: str, change: Any, match: str) -> None:
    index = _index()
    index.worlds.append(WorldEntry("zo", "normal", 7, "lumber"))
    committed = change(_step_entry(name))
    (index.regions if isinstance(committed, NamedRegion) else index.locations).append(committed)
    with pytest.raises(LevelError, match=rf"step 0 .* differs from world_index.json: '{name}' .*{match}"):
        _build(bridge, root, index=index)
    assert not fake.worlds["zt"].edits and not (root / "levels" / "zt.lock.json").exists()


def test_a_committed_entry_matching_in_any_tag_order_builds(bridge: Bridge, root: Path) -> None:
    index = _index()
    sell, entrance = _step_entry("sell_npc_tbox"), _step_entry("tbox_entrance")
    assert sell.tags == ["npc", "sell"] and entrance.tags == ["mine", "walkway"]
    index.locations.append(replace(sell, tags=["sell", "npc"]))
    index.regions.append(replace(entrance, tags=["walkway", "mine"]))
    assert _build(bridge, root, index=index).exists()


def test_a_committed_entry_with_a_non_string_tag_refuses(fake: FakeBridge, bridge: Bridge, root: Path) -> None:
    index = _index()
    index.locations.append(replace(_step_entry("sell_npc_tbox"), tags=["npc", 1]))
    with pytest.raises(LevelError, match="'sell_npc_tbox' has a tag that is not a string: 1"):
        _build(bridge, root, index=index)
    assert not fake.worlds["zt"].edits


def test_the_committed_index_file_is_byte_identical_after_a_build(bridge: Bridge, root: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = _index().save(root / "world_index.json", updated="2026-09-29T00:00:00+00:00")
    before = path.read_bytes()
    monkeypatch.setattr(world_index, "DEFAULT_PATH", path)
    assert build_level(bridge, "zt", lambda: SAVED, root=root, checks_path=root / "checks.yaml", mines_config=root / "mines.yml").exists()
    assert path.read_bytes() == before


def test_a_zone_mines_does_not_reset_is_refused_too_without_the_mines_config(fake: FakeBridge, bridge: Bridge, root: Path) -> None:
    (root / "mines.yml").unlink()
    with pytest.raises(LevelError, match="cannot read the mines world list"):
        _build(bridge, root)
    assert fake.requests == []


def test_other_zones_unresolved_checks_do_not_block(bridge: Bridge, root: Path) -> None:
    _checks(root, ZT_SPAWN, {"check": "mine_valid", "region": "mine_a", "spec": "specs/mine_a.json"},
            {"check": "warp_safe", "zone": "zo", "at": "zo_spawn"})
    assert _build(bridge, root).exists()


def test_two_steps_naming_one_entry_refuse(bridge: Bridge, root: Path) -> None:
    (root / "levels" / "zt.json").write_text(json.dumps({**RECIPE, "steps": RECIPE["steps"] * 2}), encoding="utf-8")
    with pytest.raises(LevelError, match=r"step 1 .* names \['rankup_npc_tbox'.* which an earlier step made"):
        _build(bridge, root)
    assert not (root / "levels" / "zt.lock.json").exists()


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
