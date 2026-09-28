"""``checks.yaml``'s ``no_holes`` and ``entity_clear`` entries against real ``build_plot_grid``
and ``build_signage`` output.

``_PLOT_SPEC``'s ``plot_size`` and ``buffer`` are throwaway numbers picked only to give
``no_holes`` a footprint and ``entity_clear`` a sign position to check, the same way
``test_builders_plot_grid.py``'s own ``_spec`` picks ``[4, 4]``/``2``. They are inline here,
not read from a committed ``specs/*.json`` file, and they are not a proposal: the real plot
dimensions and buffer are still open, pending the M5 plots brainstorm (design plan §10), and
these fixture numbers must never be mistaken for that decision.
"""

from designer.builders.base import Palette
from designer.builders.plot_grid import PlotGridSpec, build_plot_grid
from designer.builders.signage import SignageSpec, build_signage
from designer.checks import RunContext, load_checks, run_one
from designer.region import Bounds
from designer.world_index import Location, NamedRegion, WorldEntry, WorldIndex

PLOT_ID, SIGN_ID = "no_holes_plots_0_0_65", "entity_clear_plots_entrance_sign"

_PLOT_SPEC = {"name": "plots", "world": "plots", "origin": [0, 0], "y": 64, "rows": 2, "cols": 2, "plot_size": [7, 7], "buffer": 3}
_SIGN_SPEC = {"world": "plots", "signs": [{"name": "plots_entrance_sign", "pos": [3, 65, 3], "text": "Player Plots"}]}


def _built() -> tuple[WorldIndex, RunContext]:
    plot_spec = PlotGridSpec.from_dict(_PLOT_SPEC)
    sign_spec = SignageSpec.from_dict(_SIGN_SPEC)
    plots = build_plot_grid(plot_spec, Palette.load("mine_stone"))
    signs = build_signage(sign_spec)
    assert plots.world == signs.world

    index = WorldIndex(worlds=[WorldEntry(plots.world, "normal", 0, "plots")])
    for region in plots.extras["regions"]:
        index.add_region(NamedRegion.from_json(region))
    for location in signs.extras["locations"]:
        index.add_location(Location.from_json(location))

    region = plots.to_region()
    return index, RunContext({plots.world: region})


def _checks() -> dict[str, object]:
    return {c.id: c for c in load_checks() if c.id in (PLOT_ID, SIGN_ID)}


def test_the_committed_checks_yaml_carries_both_entries() -> None:
    found = _checks()
    assert found.keys() == {PLOT_ID, SIGN_ID}
    assert found[PLOT_ID].kind == "no_holes" and found[SIGN_ID].kind == "entity_clear"


def test_no_holes_passes_the_built_plot_and_fails_a_broken_ring() -> None:
    index, ctx = _built()
    spec = _checks()[PLOT_ID]
    assert run_one(ctx, index, spec).ok

    ctx.regions["plots"].fill(Bounds((0, 64, 0), (0, 64, 0)), "minecraft:air")
    result = run_one(ctx, index, spec)
    assert not result.ok and "holes" in result.detail


def test_entity_clear_passes_the_placed_sign_and_fails_when_buried() -> None:
    index, ctx = _built()
    spec = _checks()[SIGN_ID]
    assert run_one(ctx, index, spec).ok

    ctx.regions["plots"].fill(Bounds((3, 65, 3), (3, 65, 3)), "minecraft:stone")
    result = run_one(ctx, index, spec)
    assert not result.ok and "hitbox blocked" in result.detail
