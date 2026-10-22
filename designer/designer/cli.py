"""Command-line entry point for the ``designer`` console script."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from designer import __version__
from designer import checks as checks_mod
from designer import config
from designer import level_engine
from designer import snapshot as snapshots
from designer import stack as stack_mod
from designer import terrain as terrain_mod
from designer.bridge import Bridge, BridgeError
from designer.builders import BUILDERS
from designer.builders.base import Palette, opt
from designer.builders.mine_spec import MineSpec
from designer.config import ConfigError, load_settings
from designer.level import LevelError, refuse_name
from designer.palettes import load_palettes
from designer.region import Bounds, Bounds2D, Heightmap, Region, fetch_heightmap, fetch_region
from designer.render import Marker, ascii_heightmap, isometric_png, markers_from_index, slice_png, summary, topdown_png
from designer.verify import mine_valid
from designer.world_index import KINDS, WorldIndex, resolve_at


def _add_area(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--at", required=True, metavar="REF",
        help="A name from the index, x,z or x,y,z. A bare spawn falls back to the location tagged spawn.",
    )
    parser.add_argument("--size", required=True, type=int, metavar="N", help="Side of the square in blocks.")
    parser.add_argument("--world", metavar="W", help="Defaults to the name's world, else default_world.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="designer",
        description="RiftalGames map design toolkit.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"designer {__version__}",
    )
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("ping", help="Round-trip the bridge and print the time.")
    commands.add_parser("info", help="Print the bridge's server_info.")
    index = commands.add_parser("index", help="Query world_index.json without a server.")
    index_commands = index.add_subparsers(dest="index_command", required=True)
    listing = index_commands.add_parser("list", help="Print worlds, locations and regions as JSON.")
    listing.add_argument("--kind", choices=KINDS)
    listing.add_argument("--tag", help="Only locations and regions carrying this tag.")
    index_commands.add_parser("resolve", help="Print the location or region called NAME.").add_argument("name")
    heightmap = commands.add_parser("heightmap", help="Print an ASCII heightmap of a square around a point.")
    _add_area(heightmap)
    heightmap.add_argument("--band", type=int, metavar="B", help="Blocks of height per ramp character.")
    heightmap.add_argument("--max-width", type=int, default=128, metavar="W", help="Columns before downsampling.")
    renders = commands.add_parser("render", help="Write a PNG render into reports/.").add_subparsers(dest="render")
    renders.required = True
    topdown = renders.add_parser("topdown", help="Top-down map of a square around a point, coloured by top block.")
    _add_area(topdown)
    topdown.add_argument("--scale", type=int, default=4, metavar="S", help="Pixels per block.")
    topdown.add_argument("--out", metavar="PATH", help="Output file, default a timestamped name in reports/.")
    isometric = renders.add_parser("isometric", help="2:1 dimetric map of a square around a point, coloured by top block.")
    _add_area(isometric)
    isometric.add_argument("--scale", type=int, default=2, metavar="S", help="Pixels per block edge.")
    isometric.add_argument("--out", metavar="PATH", help="Output file, default a timestamped name in reports/.")
    slice_cmd = renders.add_parser("slice", help="Map of a square at a fixed height, coloured by the block at that y.")
    _add_area(slice_cmd)
    slice_cmd.add_argument("--y", type=int, required=True, metavar="Y", help="Height to slice at.")
    slice_cmd.add_argument("--scale", type=int, default=4, metavar="S", help="Pixels per block.")
    slice_cmd.add_argument("--out", metavar="PATH", help="Output file, default a timestamped name in reports/.")

    terrain = commands.add_parser("terrain", help="Terrain analysis, flat-site search and terraform.")
    terrains = terrain.add_subparsers(dest="terrain")
    terrains.required = True

    analyze = terrains.add_parser("analyze", help="Height stats, slope map and flat and water fractions for a square.")
    _add_area(analyze)
    analyze.add_argument("--flat-slope", type=int, default=1, metavar="N", help="Greatest neighbour step still counted as flat.")

    find_site = terrains.add_parser("find-site", help="Search a square for the flattest, driest site of a given size.")
    _add_area(find_site)
    find_site.add_argument("--site-size", type=int, required=True, metavar="N", help="Side of the site to search for.")
    find_site.add_argument("--near", metavar="REF", help="A name, x,z or x,y,z to rank sites by distance to.")
    find_site.add_argument("--max-slope", type=int, default=1, metavar="N")
    find_site.add_argument("--max-range", type=int, metavar="N", help="Defaults to --site-size.")
    find_site.add_argument("--max-water", type=float, default=0.0, metavar="F")
    find_site.add_argument("--limit", type=int, default=5, metavar="N")

    terraform = terrains.add_parser("terraform", help="Flatten, raise, lower or smooth a square. Reports a dry run unless --apply is given; exits 1 on a failed apply.")
    _add_area(terraform)
    terraform.add_argument("--mode", choices=terrain_mod.MODES, required=True)
    terraform.add_argument("--level", type=int, default=0, metavar="Y", help="Target height for flatten, raise and lower.")
    terraform.add_argument("--block", default="minecraft:stone", metavar="BLOCK", help="Fill block where the ground rises.")
    terraform.add_argument("--feather", type=int, default=0, metavar="N", help="Blocks at the edge that blend instead of cutting sharply.")
    terraform.add_argument("--smooth-radius", type=int, default=2, metavar="N")
    terraform.add_argument("--apply", action="store_true", help="Send the edits; default is a dry run that only reports them.")

    build = commands.add_parser("build", help="Build KIND from a spec and palette. Dry run by default; --apply sends it. Exits 1, dry run or not, on an index entry the build would refuse or a failing mine_valid, and on a failed apply. A failing mine_valid sends nothing.")
    build.add_argument("kind", choices=sorted(BUILDERS), metavar="KIND", help="A builder registered in designer.builders.BUILDERS.")
    build.add_argument("--spec", required=True, metavar="PATH", help="Path to a JSON spec file.")
    build.add_argument("--palette", required=True, metavar="NAME", help="A palette name from palettes.json.")
    build.add_argument("--apply", action="store_true", help="Send the edits and register the index; default is a dry run that only reports them.")
    build.add_argument("--no-verify", action="store_true", help="Skip mine_valid on the built region, so --apply sends a mine that would fail it.")
    build.add_argument("--no-index", action="store_true", help="Skip checking and registering the builder's locations and regions.")

    checks = commands.add_parser("checks", help="Run checks.yaml against the running server.")
    checks_sub = checks.add_subparsers(dest="checks")
    checks_sub.required = True
    checks_run = checks_sub.add_parser("run", help="Run every check, or only the ids named, and print the report table.")
    checks_run.add_argument("--only", nargs="+", metavar="ID", help="Run only these check ids; default every check.")
    checks_run.add_argument("--path", metavar="PATH", help="checks.yaml to read; default designer/checks.yaml.")

    stack = commands.add_parser("stack", help="Manage the designer stack container.")
    stacks = stack.add_subparsers(dest="stack")
    stacks.required = True
    stacks.add_parser("up", help="Start the designer stack detached.")
    stacks.add_parser("down", help="Send stop, wait for the shutdown line, then remove the container.")
    stacks.add_parser("logs", help="Print the container's log.")
    console_cmd = stacks.add_parser("console", help="Send one console command to the running server.")
    console_cmd.add_argument("line", help="The command to send, e.g. 'say hello'.")
    stacks.add_parser("build-image", help="Build the local-pocketmine-mp image from the pmmp-core sibling repo.")
    stacks.add_parser("build-devtools", help="Build DevTools.phar from pmmp-core's DevTools plugin.")

    level = commands.add_parser("level", help="Build zone levels from their committed recipes in levels/.")
    levels = level.add_subparsers(dest="level")
    levels.required = True
    level_build = levels.add_parser("build", help="Build ZONE on a fresh riftal_smoke_level_<zone> volume and write levels/<zone>.lock.json.")
    level_build.add_argument("zone")
    default_bridge = stack_mod.STACK_DIR.parent.parent.parent / "riftal-game" / "designbridge"
    level_build.add_argument("--designbridge", type=Path, default=default_bridge, metavar="PATH", help="DesignBridge source folder.")
    level_build.add_argument("--plugins", type=Path, default=stack_mod.STACK_DIR / "plugins", metavar="PATH", help="Folder holding DevTools.phar.")
    level_build.add_argument("--bridge-port", type=int, default=level_engine.DEFAULT_BRIDGE_PORT, metavar="PORT", help="Loopback port the build's bridge publishes on.")
    return parser


def _fetch(bridge: Bridge, options: argparse.Namespace) -> tuple[Heightmap, list[Marker]]:
    index = WorldIndex.load()
    world, (x, _, z) = resolve_at(index, options.at, options.world)
    bounds = Bounds2D.from_center((x, z), (options.size, options.size))
    return fetch_heightmap(bridge, world, bounds, need_top=True), markers_from_index(index, world, bounds)


def _heightmap(bridge: Bridge, options: argparse.Namespace) -> str:
    hm, markers = _fetch(bridge, options)
    return ascii_heightmap(hm, markers, max_width=options.max_width, band=options.band)


def _render(bridge: Bridge, options: argparse.Namespace) -> str:
    hm, markers = _fetch(bridge, options)
    render_fn = topdown_png if options.render == "topdown" else isometric_png
    path = render_fn(hm, load_palettes()["colors"], markers, scale=options.scale, out=options.out)
    stats = summary(hm)
    stats["size"] = "x".join(map(str, stats["size"]))
    return f"{path}\n" + " ".join(f"{k}={v}" for k, v in stats.items())


def _render_slice(bridge: Bridge, options: argparse.Namespace) -> str:
    index = WorldIndex.load()
    world, (x, _, z) = resolve_at(index, options.at, options.world)
    bounds2d = Bounds2D.from_center((x, z), (options.size, options.size))
    markers = markers_from_index(index, world, bounds2d)
    (x0, z0), (x1, z1) = bounds2d.min, bounds2d.max
    region = fetch_region(bridge, world, Bounds((x0, options.y - 1, z0), (x1, options.y, z1)))
    path = slice_png(region, options.y, load_palettes()["colors"], markers, scale=options.scale, out=options.out)
    return f"{path}\n" + " ".join(f"{k}={v}" for k, v in region.counts().items())


def _area_bounds(options: argparse.Namespace) -> tuple[str, Bounds2D]:
    index = WorldIndex.load()
    world, (x, _, z) = resolve_at(index, options.at, options.world)
    return world, Bounds2D.from_center((x, z), (options.size, options.size))


def _terrain_analyze(bridge: Bridge, options: argparse.Namespace) -> str:
    world, bounds = _area_bounds(options)
    hm = fetch_heightmap(bridge, world, bounds, need_top=True)
    stats = terrain_mod.analyze_terrain(hm, flat_slope=options.flat_slope)
    return json.dumps(stats.to_json(), indent=2, sort_keys=True)


def _terrain_find_site(bridge: Bridge, options: argparse.Namespace) -> str:
    world, bounds = _area_bounds(options)
    hm = fetch_heightmap(bridge, world, bounds, need_top=True)
    near = None
    if options.near is not None:
        _, near = resolve_at(WorldIndex.load(), options.near, world)
    sites = terrain_mod.find_flat_site(
        hm, options.site_size, max_slope=options.max_slope, max_range=options.max_range,
        max_water=options.max_water, near=near, limit=options.limit,
    )
    return json.dumps([s.to_json() for s in sites], indent=2, sort_keys=True)


def _emit(report: dict[str, Any]) -> int:
    print(json.dumps(report, indent=2, sort_keys=True))
    failures = [f"apply failed: {report['error']}"] if report.get("ok") is False else []
    if report.get("mine_valid", {"ok": True})["ok"] is False:
        refused = "; nothing sent, --no-verify sends it anyway" if report.get("apply") else ""
        failures.append(f"mine_valid failed: {report['mine_valid']['detail']}{refused}")
    for failure in failures:
        print(f"designer: {failure}", file=sys.stderr)
    return 1 if failures else 0


def _terrain_terraform(bridge: Bridge, options: argparse.Namespace) -> dict[str, Any]:
    world, bounds = _area_bounds(options)
    margin = options.feather + (options.smooth_radius if options.mode == "smooth" else 0)
    hm = fetch_heightmap(bridge, world, bounds.expand(margin) if margin else bounds)
    edits = terrain_mod.terraform(
        hm, bounds, mode=options.mode, level=options.level, block=options.block,
        feather=options.feather, smooth_radius=options.smooth_radius,
    )
    report: dict[str, Any] = {
        "world": world, "bounds": bounds.to_json(), "mode": options.mode, "columns": edits.extras["columns"],
        "blocks": edits.count_blocks(), "requests": len(edits.requests()), "apply": options.apply,
    }
    if options.apply:
        session = datetime.now(UTC).strftime("cli-%Y%m%dT%H%M%SZ")
        done = snapshots.apply_undoable(bridge, edits, "terraform", session)
        result = done.result
        report["snapshot"], report["undo_id"], report["ok"] = done.snapshot, done.undo_id, result.ok
        if not result.ok:
            report["error"] = str(result.errors[0])
    return report


def _build(bridge: Bridge, options: argparse.Namespace) -> dict[str, Any]:
    def fetch(world: str, bounds: Bounds2D) -> Heightmap:
        return fetch_heightmap(bridge, world, bounds)

    spec = json.loads(Path(options.spec).read_text(encoding="utf-8"))
    edits = BUILDERS[options.kind](spec, Palette.load(options.palette), fetch)
    report: dict[str, Any] = {
        "kind": options.kind, "world": edits.world, "bounds": edits.bounds.to_json() if edits.bounds else None,
        "blocks": edits.count_blocks(), "requests": len(edits.requests()), "apply": options.apply,
        "locations": edits.extras.get("locations", []), "regions": edits.extras.get("regions", []),
        "extras_report": None,
    }
    if not options.no_verify and options.kind == "mine":
        mine_spec = MineSpec.from_dict(edits.extras["mine_spec"])
        geo = mine_spec.geometry()
        region = edits.to_region(Region.empty(mine_spec.world, geo.padding.union(geo.exit_platform)))
        found = mine_valid(region, mine_spec)
        report["mine_valid"] = {"ok": found.ok, "detail": found.detail}
    idx = None if options.no_index else WorldIndex.load()
    taken = idx.preflight(report["locations"], report["regions"]) if idx is not None else []
    if taken:
        raise ValueError(f"{taken} already defined; build a differently named spec, or pass --no-index to build without registering")
    if report.get("mine_valid", {"ok": True})["ok"] is False:
        return report
    if options.apply:
        session = datetime.now(UTC).strftime("cli-%Y%m%dT%H%M%SZ")
        done = snapshots.apply_undoable(bridge, edits, f"build_{options.kind}", session)
        result = done.result
        report["snapshot"], report["undo_id"], report["ok"] = done.snapshot, done.undo_id, result.ok
        if not result.ok:
            report["error"] = str(result.errors[0])
        elif idx is not None:
            idx.register(report["locations"], report["regions"])
            idx.save()
        config.REPORTS_DIR.mkdir(parents=True, exist_ok=True)
        report_path = config.REPORTS_DIR / f"{options.kind}-{opt(spec, 'name', options.kind)}-extras.json"
        report_path.write_text(json.dumps(edits.extras, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
        report["extras_report"] = str(report_path)
    return report


def _checks_table(report: checks_mod.Report) -> str:
    failed = report.failed
    header = f"{len(report.results) - len(failed)} passed, {len(failed)} failed of {len(report.results)}."
    rows = [f"{r.id} | {r.check} | {'yes' if r.ok else 'no'} | {r.seconds:.2f} | {r.detail}" for r in report.results]
    return "\n".join([header, *rows])


def _checks_run(bridge: Bridge, options: argparse.Namespace) -> int:
    specs = checks_mod.load_checks(Path(options.path) if options.path else None)
    report = checks_mod.run_checks(bridge, WorldIndex.load(), specs, only=options.only)
    path = checks_mod.write_report(report)
    print(path)
    print(_checks_table(report))
    return 1 if report.failed else 0


def _run_index(options: argparse.Namespace) -> int:
    try:
        index = WorldIndex.load()
        if options.index_command == "resolve":
            print(json.dumps(index.resolve(options.name).to_json(), sort_keys=True))
            return 0
        listing = index.select(options.kind, options.tag)
    except (OSError, ValueError, KeyError) as exc:
        print(f"designer: {exc.args[0] if isinstance(exc, KeyError) else exc}", file=sys.stderr)
        return 1
    print(json.dumps(listing, indent=2, sort_keys=True))
    return 0


def _stack(options: argparse.Namespace) -> str:
    runtime = stack_mod.runtime_name()
    if options.stack == "up":
        stack_mod.up(runtime)
        return "up"
    if options.stack == "down":
        stack_mod.down(runtime)
        return "down"
    if options.stack == "logs":
        return stack_mod.logs(runtime)
    if options.stack == "console":
        stack_mod.console(runtime, options.line)
        return f"sent: {options.line}"
    if options.stack == "build-image":
        stack_mod.build_image(runtime)
        return f"built {stack_mod.IMAGE}"
    stack_mod.build_devtools(runtime)
    return "built DevTools.phar"


def _level(options: argparse.Namespace) -> str:
    refuse_name(options.zone)
    if not options.designbridge.is_dir():
        raise LevelError(f"no DesignBridge source at {options.designbridge}; pass --designbridge")
    if not (options.plugins / "DevTools.phar").is_file():
        raise LevelError(f"{options.plugins} holds no DevTools.phar, which loads DesignBridge from source; run 'designer stack build-devtools'")
    sources = level_engine.Sources(options.designbridge.resolve(), options.plugins.resolve(), options.bridge_port)
    lock = level_engine.build(options.zone, stack_mod.runtime_name(), sources)
    return f"{lock}\ncontent_sha256={json.loads(lock.read_text(encoding='utf-8'))['content_sha256']}"


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    options = parser.parse_args(argv)
    if options.command is None:
        parser.print_help()
        return 0
    if options.command == "index":
        return _run_index(options)
    if options.command in ("stack", "level"):
        try:
            print(_stack(options) if options.command == "stack" else _level(options))
        except (stack_mod.StackError, LevelError, BridgeError) as exc:
            print(f"designer: {exc}", file=sys.stderr)
            return 1
        return 0
    try:
        settings = load_settings()
        with Bridge(settings.host, settings.port, settings.token) as bridge:
            if options.command == "ping":
                print(f"pong from {bridge.host}:{bridge.port} in {bridge.ping() * 1000:.1f} ms")
            elif options.command == "info":
                print(json.dumps(bridge.server_info(), indent=2, sort_keys=True))
            elif options.command == "render":
                handler = {"topdown": _render, "isometric": _render, "slice": _render_slice}[options.render]
                print(handler(bridge, options))
            elif options.command == "terrain" and options.terrain == "terraform":
                return _emit(_terrain_terraform(bridge, options))
            elif options.command == "terrain":
                handler = {"analyze": _terrain_analyze, "find-site": _terrain_find_site}[options.terrain]
                print(handler(bridge, options))
            elif options.command == "build":
                return _emit(_build(bridge, options))
            elif options.command == "checks":
                return _checks_run(bridge, options)
            else:
                print(_heightmap(bridge, options))
    except (ConfigError, BridgeError, KeyError, ValueError) as exc:
        message = exc.args[0] if isinstance(exc, KeyError) else exc
        print(f"designer: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
