import pytest

from designer.builders.base import DIRS, Palette, facing_state, opposite, opt, perpendicular, require


def test_palette_load_resolves_role() -> None:
    palette = Palette.load("mine_stone")
    assert palette.block("stairs") == "minecraft:stone_brick_stairs"
    assert palette.block("sign") == "minecraft:standing_sign"


def test_palette_load_unknown_name_names_the_palettes() -> None:
    with pytest.raises(ValueError, match="unknown palette 'nope'"):
        Palette.load("nope")


def test_palette_missing_role_names_the_role() -> None:
    palette = Palette("mine_stone", {"wall": "minecraft:stone_bricks"})
    with pytest.raises(ValueError, match="palette 'mine_stone' has no role 'stairs'"):
        palette.block("stairs")


def test_require_returns_present_field() -> None:
    assert require({"name": "box"}, "name") == "box"


def test_require_missing_field_names_it() -> None:
    with pytest.raises(ValueError, match="missing required field 'name'"):
        require({}, "name")


def test_opt_returns_present_field_or_default() -> None:
    assert opt({"seed": 5}, "seed", 0) == 5
    assert opt({}, "seed", 0) == 0
    assert opt({}, "seed") is None


@pytest.mark.parametrize("direction, expected", [("north", "south"), ("south", "north"), ("east", "west"), ("west", "east")])
def test_opposite(direction: str, expected: str) -> None:
    assert opposite(direction) == expected


def test_opposite_rejects_unknown_direction() -> None:
    with pytest.raises(ValueError, match="direction must be one of"):
        opposite("up")


@pytest.mark.parametrize("direction, expected", [
    ("north", ("east", "west")), ("south", ("east", "west")),
    ("east", ("north", "south")), ("west", ("north", "south")),
])
def test_perpendicular(direction: str, expected: tuple[str, str]) -> None:
    assert perpendicular(direction) == expected


def test_perpendicular_rejects_unknown_direction() -> None:
    with pytest.raises(ValueError, match="direction must be one of"):
        perpendicular("up")


def test_dirs_covers_every_direction_with_a_unit_step() -> None:
    assert set(DIRS) == {"north", "south", "east", "west"}
    assert all(abs(dx) + abs(dz) == 1 for dx, dz in DIRS.values())


@pytest.mark.parametrize("direction, weirdo", [("east", 0), ("west", 1), ("south", 2), ("north", 3)])
def test_facing_state_stairs_direction(direction: str, weirdo: int) -> None:
    result = facing_state("minecraft:stone_brick_stairs", direction)
    assert f"weirdo_direction={weirdo}" in result
    assert "upside_down_bit=false" in result
    assert "minecraft:corner=none" in result


def test_facing_state_stairs_upside_down() -> None:
    result = facing_state("minecraft:stone_brick_stairs", "north", half="top")
    assert "upside_down_bit=true" in result


def test_facing_state_stairs_requires_a_known_direction() -> None:
    with pytest.raises(ValueError, match="stairs need a direction"):
        facing_state("minecraft:stone_brick_stairs", "up")


@pytest.mark.parametrize("half, bit", [("top", "true"), ("bottom", "false")])
def test_facing_state_slab_half(half: str, bit: str) -> None:
    result = facing_state("minecraft:stone_brick_slab", half=half)
    assert f"top_slot_bit={bit}" in result


def test_facing_state_slab_requires_half() -> None:
    with pytest.raises(ValueError, match="slab needs half"):
        facing_state("minecraft:stone_brick_slab")


def test_facing_state_wall_connections() -> None:
    result = facing_state("minecraft:cobblestone_wall", connect=("north", "south"))
    assert "wall_connection_type_north=short" in result
    assert "wall_connection_type_east=none" in result
    assert "wall_post_bit=false" in result


def test_facing_state_wall_post_bit_true_off_a_straight_run() -> None:
    result = facing_state("minecraft:cobblestone_wall", connect=("north", "east"))
    assert "wall_post_bit=true" in result


def test_facing_state_wall_rejects_unknown_direction() -> None:
    with pytest.raises(ValueError, match="wall connections must be in"):
        facing_state("minecraft:cobblestone_wall", connect=("up",))


@pytest.mark.parametrize("direction, rotation", [("south", 0), ("west", 4), ("north", 8), ("east", 12)])
def test_facing_state_sign_rotation(direction: str, rotation: int) -> None:
    result = facing_state("minecraft:standing_sign", direction)
    assert f"ground_sign_direction={rotation}" in result


def test_facing_state_sign_requires_a_known_direction() -> None:
    with pytest.raises(ValueError, match="sign needs a direction"):
        facing_state("minecraft:standing_sign", "up")


def test_facing_state_unrecognised_block_is_returned_unchanged() -> None:
    assert facing_state("minecraft:stone", "north") == "minecraft:stone"


def test_facing_state_keeps_existing_states() -> None:
    result = facing_state("minecraft:stone_brick_stairs[custom_state=1]", "north")
    assert "custom_state=1" in result
    assert "weirdo_direction=3" in result
