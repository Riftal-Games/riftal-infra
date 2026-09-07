import json
from functools import reduce
from itertools import combinations

import numpy as np
import pytest

from designer.blocks import AIR, BlockClass
from designer.bridge import Bridge, BridgeOpError, JobFailed
from designer.edits import EditList, Fill, Replace, SetBlock, Text
from designer.region import MAX_EDGE, Bounds, Region, fetch_region
from tests.fake_bridge import FakeBridge

WORLD = "design"
STONE, DIRT, PLANKS, GLASS, WATER = "minecraft:stone", "minecraft:dirt", "minecraft:oak_planks", "minecraft:glass", "minecraft:water"
BOX = Bounds((0, 60, 0), (9, 66, 9))


def _mixed() -> EditList:
    ops = [SetBlock(x, 64, 0, PLANKS) for x in range(10)]
    ops += [Fill(Bounds((2, 60, 2), (9, 66, 9)), GLASS), Replace(BOX, STONE, DIRT), SetBlock(2, 60, 2, AIR), Text(5, 68, 5, "welcome", "sign_1")]
    return EditList(WORLD, ops, {"note": "mixed"})


def test_apply_then_fetch_equals_to_region_on_the_base(fake: FakeBridge, bridge: Bridge) -> None:
    edits, base = _mixed(), fetch_region(bridge, WORLD, BOX)
    assert edits.bounds == BOX and edits.count_blocks() == 10 + 448 + 700 + 1
    result = edits.apply(bridge)
    assert (result.ok, result.errors, len(result.jobs), result.blocks) == (True, [], 5, 1159)
    assert [r["op"] for r in fake.requests][1:] == ["set_blocks", "fill", "replace", "set_blocks", "set_text"]
    after, expected = fetch_region(bridge, WORLD, BOX), edits.to_region(base)
    np.testing.assert_array_equal(np.array(after.palette)[after.blocks], np.array(expected.palette)[expected.blocks])
    assert [after.get(*p) for p in ((2, 60, 2), (5, 63, 5), (0, 62, 0), (0, 64, 0), (1, 63, 1))] == [AIR, GLASS, DIRT, PLANKS, "minecraft:grass_block"]
    assert fake.texts["sign_1"] == {"world": WORLD, "pos": [5, 68, 5], "text": "welcome"} and result.jobs[-1]["result"] == {"id": "sign_1"}
    assert bridge.call("remove_text", id="sign_1") == {} and fake.texts == {}
    with pytest.raises(ValueError, match="outside"):
        edits.to_region(fetch_region(bridge, WORLD, Bounds((0, 60, 0), (5, 66, 5))))


def test_ten_thousand_set_blocks_take_three_calls(fake: FakeBridge, bridge: Bridge) -> None:
    xs, zs = np.meshgrid(np.arange(100, dtype=np.int64), np.arange(100, dtype=np.int64))
    edits = EditList(WORLD, [SetBlock(x, np.int64(70), z, STONE) for x, z in zip(xs.ravel(), zs.ravel())])
    assert type(edits.ops[0].x) is int and edits.count_blocks() == 10000
    seen: list[tuple[int, int]] = []
    result = edits.apply(bridge, on_progress=lambda done, total: seen.append((done, total)))
    assert result.ok and [r["op"] for r in fake.requests] == ["set_blocks"] * 3 and result.blocks == 10000
    assert [len(r["args"]["blocks"]) for r in fake.requests] == [4096, 4096, 1808] == [job["progress"]["total"] for job in result.jobs]
    assert seen == [(4096, 10000), (8192, 10000), (10000, 10000)]
    assert (fake.worlds[WORLD].blocks(Bounds((0, 70, 0), (99, 70, 99))) == 0).all()
    with pytest.raises(BridgeOpError, match="TOO_MANY_BLOCKS"):
        bridge.call("set_blocks", world=WORLD, blocks=[[0, 0, 0, STONE]] * 65537)
    with pytest.raises(ValueError, match="batch"):
        edits.apply(bridge, batch=65537)


def test_coalesce_turns_an_eight_run_into_a_fill_and_leaves_seven_alone() -> None:
    eight = [SetBlock(x, 64, 0, STONE) for x in range(8)]
    seven = [SetBlock(x, 64, 1, STONE) for x in range(7)]
    broken = [SetBlock(x, 64, 2, DIRT if x == 3 else STONE) for x in range(8)]
    text = Text(0, 65, 0, "t")
    edits = EditList(WORLD, eight + [text] + seven + broken, {"k": 1})
    out = edits.coalesce()
    assert out.ops == [Fill(Bounds((0, 64, 0), (7, 64, 0)), STONE), text, *seven, *broken]
    assert (out.world, out.extras, out.count_blocks()) == (WORLD, {"k": 1}, edits.count_blocks())
    assert [out.to_region().get(x, 64, z) for x in range(8) for z in range(3)] == [edits.to_region().get(x, 64, z) for x in range(8) for z in range(3)]
    assert EditList(WORLD, seven + seven).coalesce().ops == seven + seven


def test_coalesce_keeps_a_fill_between_two_runs_in_place() -> None:
    row = [SetBlock(x, 64, 0, STONE) for x in range(16)]
    middle = Fill(Bounds((4, 64, 0), (11, 64, 0)), DIRT)
    edits = EditList(WORLD, row[:8] + [middle] + row[8:])
    out = edits.coalesce()
    assert out.ops == [Fill(Bounds((0, 64, 0), (7, 64, 0)), STONE), middle, Fill(Bounds((8, 64, 0), (15, 64, 0)), STONE)]
    painted = [out.to_region().get(x, 64, 0) for x in range(16)]
    assert painted == [edits.to_region().get(x, 64, 0) for x in range(16)] == [STONE] * 4 + [DIRT] * 4 + [STONE] * 8


def test_fill_and_replace_paint_refresh_a_warm_class_cache() -> None:
    region, box = Region.empty(WORLD, BOX), Bounds((0, 60, 0), (3, 60, 3))
    region.index_of(STONE), region.index_of(WATER)
    assert not region.classes().any()
    Fill(box, STONE).paint(region)
    assert region.classes()[0, 0, 0] == BlockClass.SOLID and region.classes()[0, 0, 4] == BlockClass.AIR
    Replace(box, STONE, WATER).paint(region)
    assert region.classes()[0, 0, 0] == BlockClass.LIQUID and region.classes()[0, 0, 4] == BlockClass.AIR


def test_block_names_are_canonical_on_every_op() -> None:
    assert SetBlock(0, 0, 0, "stone") == SetBlock(0, 0, 0, "minecraft:stone")
    assert Fill(BOX, " oak_log[ pillar_axis = y ]").block == "minecraft:oak_log[pillar_axis=y]"
    replace = Replace(BOX, ["stone", "minecraft:dirt"], "glass")
    assert (replace.from_block, replace.to_block) == ((STONE, DIRT), GLASS)
    edits = EditList(WORLD, [SetBlock(0, 60, 0, "stone"), SetBlock(1, 60, 0, "minecraft:stone")])
    assert edits.to_region().palette == [AIR, STONE] and EditList.from_json(edits.to_json()) == edits
    assert edits.requests()[0][1]["blocks"] == [[0, 60, 0, STONE], [1, 60, 0, STONE]]
    with pytest.raises(ValueError, match="no base"):
        SetBlock(0, 0, 0, "")


def test_a_fill_wider_than_max_edge_is_sent_as_one_job_per_tile(fake: FakeBridge, bridge: Bridge) -> None:
    wide = Bounds((0, 64, 0), (299, 64, 0))
    edits = EditList(WORLD, [SetBlock(0, 65, 0, STONE), Fill(wide, GLASS), Text(0, 66, 0, "t")])
    requests = edits.requests()
    assert [op for op, _, _ in requests] == ["set_blocks", "fill", "fill", "fill", "set_text"]
    tiles = [Bounds.from_json(args["bounds"]) for op, args, _ in requests if op == "fill"]
    assert reduce(Bounds.union, tiles) == wide and sum(blocks for op, _, blocks in requests if op == "fill") == 300
    assert all(a.intersect(b) is None for a, b in combinations(tiles, 2)) and max(max(t.size) for t in tiles) <= MAX_EDGE
    assert [op for op, _, _ in EditList(WORLD, [Replace(wide, STONE, DIRT)]).requests()] == ["replace"] * 3
    seen: list[Bounds] = []
    result = edits.apply(bridge, before=lambda world, bounds: seen.append(bounds))
    assert seen == [Bounds((0, 64, 0), (299, 65, 0))]
    assert (result.ok, result.blocks, [r["op"] for r in fake.requests]) == (True, 301, ["set_blocks", "fill", "fill", "fill", "set_text"])
    assert (fake.worlds[WORLD].blocks(wide) == fake.worlds[WORLD].index_of(GLASS)).all()


def test_json_round_trip() -> None:
    edits = _mixed()
    edits.ops.append(Replace(Bounds((0, 0, 0), (1, 1, 1)), (STONE, DIRT), GLASS))
    data = json.loads(json.dumps(edits.to_json()))
    assert EditList.from_json(data) == edits and EditList.from_json(EditList(WORLD).to_json()) == EditList(WORLD)
    assert data["ops"][0] == {"op": "set_block", "pos": [0, 64, 0], "block": PLANKS} and data["ops"][-1]["from"] == [STONE, DIRT]
    assert EditList(WORLD).bounds is None and data["ops"][-2]["id"] == "sign_1"
    by_hand = {"world": WORLD, "ops": [{"op": "replace", "bounds": BOX.to_json(), "from": "stone", "to": "dirt"}]}
    assert EditList.from_json(by_hand).ops == [Replace(BOX, STONE, DIRT)]
    with pytest.raises(ValueError, match="no block ops"):
        EditList(WORLD).to_region()
    with pytest.raises(ValueError, match="unknown op"):
        EditList.from_json({"world": WORLD, "ops": [{"op": "nope"}]})


def test_dry_run_sends_nothing_and_before_runs_once_ahead_of_any_request(fake: FakeBridge, bridge: Bridge) -> None:
    edits, seen = _mixed(), []
    untouched = fake.worlds[WORLD].blocks(BOX).copy()

    def before(world: str, bounds: Bounds) -> str:
        seen.append((world, bounds, len(fake.requests)))
        return "snap"

    result = edits.apply(bridge, dry_run=True, before=before)
    assert (result.ok, result.jobs, result.blocks, result.before_result, seen) == (True, [], 0, None, [])
    assert fake.requests == [] and fake.texts == {}
    np.testing.assert_array_equal(fake.worlds[WORLD].blocks(BOX), untouched)
    result = edits.apply(bridge, before=before)
    assert result.ok and result.before_result == "snap" and seen == [(WORLD, BOX, 0)]
    assert EditList(WORLD, [Text(0, 0, 0, "x")]).apply(bridge, before=before).ok and len(seen) == 1


def test_block_invalid_mid_list_stops_and_keeps_the_earlier_jobs(fake: FakeBridge, bridge: Bridge) -> None:
    first, last = Fill(Bounds((0, 64, 0), (3, 64, 3)), GLASS), Fill(Bounds((0, 66, 0), (3, 66, 3)), GLASS)
    result = EditList(WORLD, [first, SetBlock(0, 65, 0, "minecraft:bogus"), last]).apply(bridge)
    assert (result.ok, len(result.jobs), result.jobs[0]["op"], result.blocks) == (False, 1, "fill", 16)
    assert [type(e) for e in result.errors] == [BridgeOpError] and result.errors[0].code == "BLOCK_INVALID"
    assert "blocks[0]" in str(result.errors[0]) and [r["op"] for r in fake.requests] == ["fill", "set_blocks"]
    after = fetch_region(bridge, WORLD, Bounds((0, 64, 0), (3, 66, 3)))
    assert [after.get(0, y, 0) for y in (64, 65, 66)] == [GLASS, AIR, AIR]


def test_a_job_that_fails_mid_apply_stops_with_the_earlier_jobs_recorded(fake: FakeBridge, bridge: Bridge) -> None:
    fills = [Fill(Bounds((0, 64 + i, 0), (3, 64 + i, 3)), GLASS) for i in range(3)]

    def arm(done: int, total: int) -> None:
        # Fires once the first job has settled, so the fault lands on the second.
        if len(fake.jobs) == 1:
            fake.fail_next_job = "chunk not generated"

    result = EditList(WORLD, fills).apply(bridge, on_progress=arm)
    assert (result.ok, [job["op"] for job in result.jobs], result.blocks) == (False, ["fill"], 16)
    assert [type(e) for e in result.errors] == [JobFailed] and result.errors[0].error == "chunk not generated"
    assert [r["op"] for r in fake.requests] == ["fill", "fill"]
    assert fetch_region(bridge, WORLD, Bounds((0, 66, 0), (3, 66, 3))).get(0, 66, 0) == AIR
