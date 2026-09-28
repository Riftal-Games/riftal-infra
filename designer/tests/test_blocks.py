import time
from itertools import permutations

import numpy as np
import pytest

from designer import blocks
from designer.blocks import (
    AIR, RLE_ORDER, BlockClass, RLEError, base_name, class_lut, classify,
    decode_rle, encode_rle, format_name, parse_name, register_rule,
)

ORDERS = [tuple(p) for p in permutations("yzx")]


@pytest.fixture
def rules():
    saved = list(blocks.CLASS_RULES)
    yield blocks.CLASS_RULES
    blocks.CLASS_RULES[:] = saved


@pytest.mark.parametrize("name, base, states", [
    ("minecraft:stone", "minecraft:stone", {}),
    ("stone", "minecraft:stone", {}),
    ("oak_log[pillar_axis=y]", "minecraft:oak_log", {"pillar_axis": "y"}),
    ("minecraft:lever[open_bit=true,lever_direction=1]", "minecraft:lever", {"open_bit": "true", "lever_direction": "1"}),
    ("  stone [ pillar_axis = y , open_bit=true ] ", "minecraft:stone", {"pillar_axis": "y", "open_bit": "true"}),
])
def test_parse_name(name: str, base: str, states: dict[str, str]) -> None:
    assert parse_name(name) == (base, states)


@pytest.mark.parametrize("name", ["minecraft:stone", "minecraft:oak_log[pillar_axis=y]", "minecraft:stone[]"])
def test_format_round_trip_is_canonical(name: str) -> None:
    assert format_name(*parse_name(name)) == name.replace("[]", "")


def test_format_name_sorts_states_and_adds_namespace() -> None:
    assert format_name("lever", {"open_bit": True, "lever_direction": 1}) == "minecraft:lever[lever_direction=1,open_bit=true]"
    assert format_name(*parse_name("lever[open_bit=true,lever_direction=1]")) == "minecraft:lever[lever_direction=1,open_bit=true]"


@pytest.mark.parametrize("bad", ["", "stone[pillar_axis=y", "stone[=y]", "stone[axis]"])
def test_malformed_name_raises(bad: str) -> None:
    with pytest.raises(ValueError):
        parse_name(bad)


def test_base_name_strips_namespace_and_states() -> None:
    assert base_name("minecraft:oak_log[pillar_axis=y]") == "oak_log"
    assert base_name("stone") == "stone"


@pytest.mark.parametrize("name, cls", [
    ("minecraft:air", BlockClass.AIR),
    ("cave_air", BlockClass.AIR),
    ("minecraft:water[liquid_depth=3]", BlockClass.LIQUID),
    ("bubble_column", BlockClass.LIQUID),
    ("lava", BlockClass.DANGER),
    ("soul_campfire", BlockClass.DANGER),
    ("sweet_berry_bush", BlockClass.DANGER),
    ("redstone_torch", BlockClass.PASSABLE),
    ("oak_wall_sign", BlockClass.PASSABLE),
    ("stone_pressure_plate", BlockClass.PASSABLE),
    ("tripwire_hook", BlockClass.PASSABLE),
    ("short_grass", BlockClass.PASSABLE),
    ("grass_block", BlockClass.SOLID),
    ("stone", BlockClass.SOLID),
    ("some_future_block", BlockClass.SOLID),
])
def test_classify_defaults(name: str, cls: BlockClass) -> None:
    assert classify(name) is cls


def test_mangrove_roots_are_solid_and_hanging_roots_passable() -> None:
    assert classify("hanging_roots") is BlockClass.PASSABLE
    assert classify("minecraft:mangrove_roots") is BlockClass.SOLID


# Names exactly as DesignBridge's get_region returned them on a v26.50 core
# (riftal-infra#59). A block with no collision box is walked through and
# cannot be stood on, so it is PASSABLE; a SOLID answer there would let a
# floor check pass over a block a player falls through.
@pytest.mark.parametrize("name", [
    "minecraft:wheat[growth=0]",
    "minecraft:carrots[growth=0]",
    "minecraft:potatoes[growth=0]",
    "minecraft:beetroot[growth=0]",
    "minecraft:pitcher_crop[growth=0,upper_block_bit=false]",
    "minecraft:melon_stem[facing_direction=0,growth=0]",
    "minecraft:pumpkin_stem[facing_direction=0,growth=0]",
    "minecraft:nether_wart[age=0]",
    "minecraft:web",
    "cobweb",
    "minecraft:light_block_0",
    "minecraft:light_block_15",
    "light_block",
    "minecraft:trip_wire[attached_bit=false,disarmed_bit=false,powered_bit=false,suspended_bit=false]",
    "minecraft:deadbush",
    "minecraft:structure_void",
    "minecraft:small_dripleaf_block[minecraft:cardinal_direction=north,upper_block_bit=false]",
    "minecraft:glow_lichen[multi_face_direction_bits=0]",
    "minecraft:resin_clump[multi_face_direction_bits=0]",
    "minecraft:spore_blossom",
    "minecraft:red_mushroom",
    "minecraft:brown_mushroom",
    "minecraft:crimson_roots",
    "minecraft:warped_roots",
    "minecraft:nether_sprouts",
    "minecraft:pink_petals[growth=0,minecraft:cardinal_direction=north]",
    "minecraft:standing_sign[ground_sign_direction=0]",
    "minecraft:torchflower_crop[growth=0]",
    "minecraft:short_grass",
])
def test_bridge_names_without_collision_are_passable(name: str) -> None:
    assert classify(name) is BlockClass.PASSABLE


@pytest.mark.parametrize("name", [
    "minecraft:chorus_flower[age=0]",
    "minecraft:end_rod[facing_direction=0]",
    "minecraft:iron_chain[pillar_axis=y]",
    "minecraft:mangrove_roots",
    "minecraft:muddy_mangrove_roots[pillar_axis=y]",
    "minecraft:lantern[hanging=false]",
    "minecraft:barrier",
    "minecraft:crimson_stem[pillar_axis=y]",
    "minecraft:cocoa[age=0,direction=0]",
    "minecraft:azalea",
    "minecraft:stone_brick_slab[minecraft:vertical_half=bottom]",
    "minecraft:grass_block",
    "minecraft:oak_leaves[persistent_bit=false,update_bit=false]",
    "minecraft:bedrock[infiniburn_bit=false]",
])
def test_bridge_names_with_collision_are_solid(name: str) -> None:
    assert classify(name) is BlockClass.SOLID


def test_bridge_liquid_and_danger_names() -> None:
    assert classify("minecraft:flowing_water[liquid_depth=0]") is BlockClass.LIQUID
    assert classify("minecraft:flowing_lava[liquid_depth=0]") is BlockClass.DANGER


def test_register_rule_front_overrides_and_back_only_fills_gaps(rules: list) -> None:
    register_rule("exact", "some_future_block", BlockClass.PASSABLE, front=False)
    assert classify("some_future_block") is BlockClass.PASSABLE
    register_rule("exact", "stone", BlockClass.DANGER, front=False)
    assert classify("stone") is BlockClass.DANGER
    register_rule("suffix", "torch", BlockClass.DANGER, front=False)
    assert classify("redstone_torch") is BlockClass.PASSABLE
    register_rule("suffix", "torch", BlockClass.DANGER, front=True)
    assert classify("redstone_torch") is BlockClass.DANGER
    with pytest.raises(ValueError):
        register_rule("regex", "x", BlockClass.SOLID)


def test_class_lut_follows_palette_order() -> None:
    lut = class_lut([AIR, "minecraft:stone", "water", "minecraft:lava", "torch"])
    assert lut.dtype == np.uint8
    assert lut.tolist() == [0, 1, 2, 4, 3]


def test_decode_lays_runs_x_fastest_then_z_then_y() -> None:
    payload = {
        "min": [0, 0, 0], "max": [1, 1, 2], "order": "yzx",
        "palette": [AIR, "a", "b", "c", "d", "e"],
        "runs": [[0, 1], [1, 1], [2, 1], [3, 1], [4, 1], [5, 1], [0, 6]],
    }
    arr, _ = decode_rle(payload)
    assert arr.shape == (2, 3, 2)
    assert arr.dtype == np.int16
    assert arr[0].tolist() == [[0, 1], [2, 3], [4, 5]]
    assert not arr[1].any()


@pytest.mark.parametrize("order", ORDERS)
def test_rle_round_trip(order: tuple[str, str, str]) -> None:
    rng = np.random.default_rng(7)
    palette = [AIR, "minecraft:stone", "minecraft:water", "minecraft:oak_log[pillar_axis=y]"]
    original = rng.integers(0, len(palette), size=(5, 7, 11), dtype=np.int16)
    payload = encode_rle(original, palette, order=order, origin=(-3, 40, 9))
    decoded, decoded_palette = decode_rle(payload, order=order)
    assert payload["order"] == "".join(order)
    assert payload["min"] == [-3, 40, 9] and payload["max"] == [7, 44, 15]
    assert payload["volume"] == original.size
    assert decoded_palette == palette
    np.testing.assert_array_equal(decoded, original)


def test_encode_order_changes_the_runs() -> None:
    arr, palette = np.arange(24, dtype=np.int16).reshape(2, 3, 4), [str(i) for i in range(24)]
    assert encode_rle(arr, palette)["runs"] != encode_rle(arr, palette, order=("x", "z", "y"))["runs"]


def test_decode_rejects_payload_order_mismatch() -> None:
    payload = encode_rle(np.zeros((1, 1, 1), dtype=np.int16), [AIR], order=("x", "y", "z"))
    with pytest.raises(RLEError, match="order"):
        decode_rle(payload, order=RLE_ORDER)


@pytest.mark.parametrize("palette, row, expected_palette, expected_row", [
    (["stone", "dirt"], [0, 1, 1], [AIR, "stone", "dirt"], [1, 2, 2]),
    ([AIR, "stone"], [0, 1, 0], [AIR, "stone"], [0, 1, 0]),
    (["stone", "dirt", AIR], [0, 1, 2, 2], [AIR, "dirt", "stone"], [2, 1, 0, 0]),
], ids=["air absent", "air at 0", "air at k"])
def test_air_is_remapped_to_index_zero(palette, row, expected_palette, expected_row) -> None:
    arr, decoded_palette = decode_rle(encode_rle(np.array([[row]], dtype=np.int16), palette))
    assert decoded_palette == expected_palette
    assert arr.tolist() == [[expected_row]]


def test_volume_mismatch_raises() -> None:
    payload = {"min": [0, 0, 0], "max": [1, 1, 1], "palette": [AIR], "runs": [[0, 7]]}
    with pytest.raises(RLEError, match="runs cover 7 blocks, bounds hold 8"):
        decode_rle(payload)


@pytest.mark.parametrize("runs", [[[0, 9], [0, -1]], [[0, 8], [0, 0]]], ids=["negative", "zero"])
def test_run_count_below_one_raises(runs: list[list[int]]) -> None:
    payload = {"min": [0, 0, 0], "max": [1, 1, 1], "palette": [AIR], "runs": runs}
    with pytest.raises(RLEError, match="run count"):
        decode_rle(payload)


def test_uniform_region_is_one_run() -> None:
    payload = encode_rle(np.ones((4, 4, 4), dtype=np.int16), [AIR, "stone"])
    assert payload["runs"] == [[1, 64]]


def test_decode_128_cube_is_fast() -> None:
    edge, run = 128, 64
    runs = edge**3 // run
    payload = {
        "min": [0, 0, 0], "max": [edge - 1] * 3,
        "palette": ["stone", "dirt", "gravel", AIR],
        "runs": [[i % 4, run] for i in range(runs)],
    }
    started = time.perf_counter()
    arr, palette = decode_rle(payload)
    elapsed = time.perf_counter() - started
    assert arr.shape == (edge, edge, edge)
    assert palette[0] == AIR
    assert elapsed < 1.0, f"decode 128^3 with {runs} runs took {elapsed * 1000:.0f} ms"
