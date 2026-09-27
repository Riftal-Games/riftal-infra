"""Command-line entry point for the ``designer`` console script."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from designer import __version__
from designer import snapshot as snapshots
from designer import terrain as terrain_mod
from designer.bridge import Bridge, BridgeError
from designer.config import ConfigError, load_settings
from designer.palettes import load_palettes
from designer.region import Bounds2D, Heightmap, fetch_heightmap
from designer.render import Marker, ascii_heightmap, markers_from_index, summary, topdown_png
from designer.world_index import WorldIndex, resolve_at


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

    terraform = terrains.add_parser("terraform", help="Flatten, raise, lower or smooth a square. Reports a dry run unless --apply is given.")
    _add_area(terraform)
    terraform.add_argument("--mode", choices=terrain_mod.MODES, required=True)
    terraform.add_argument("--level", type=int, default=0, metavar="Y", help="Target height for flatten, raise and lower.")
    terraform.add_argument("--block", default="minecraft:stone", metavar="BLOCK", help="Fill block where the ground rises.")
    terraform.add_argument("--feather", type=int, default=0, metavar="N", help="Blocks at the edge that blend instead of cutting sharply.")
    terraform.add_argument("--smooth-radius", type=int, default=2, metavar="N")
    terraform.add_argument("--apply", action="store_true", help="Send the edits; default is a dry run that only reports them.")
    return parser


def _fetch(bridge: Bridge, options: argparse.Namespace) -> tuple[Heightmap, list[Marker]]:
    index = WorldIndex.load()
    world, (x, _, z) = resolve_at(index, options.at, options.world)
    bounds = Bounds2D.from_center((x, z), (options.size, options.size))
    return fetch_heightmap(bridge, world, bounds, need_top=True), markers_from_index(index, world, bounds)


def _heightmap(bridge: Bridge, options: argparse.Namespace) -> str:
    hm, markers = _fetch(bridge, options)
    return ascii_heightmap(hm, markers, max_width=options.max_width, band=options.band)


def _topdown(bridge: Bridge, options: argparse.Namespace) -> str:
    hm, markers = _fetch(bridge, options)
    path = topdown_png(hm, load_palettes()["colors"], markers, scale=options.scale, out=options.out)
    stats = summary(hm)
    stats["size"] = "x".join(map(str, stats["size"]))
    return f"{path}\n" + " ".join(f"{k}={v}" for k, v in stats.items())


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


def _terrain_terraform(bridge: Bridge, options: argparse.Namespace) -> str:
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
    if options.apply and edits.bounds is not None:
        report["snapshot"] = str(snapshots.take(bridge, world, edits.bounds, "terraform").path)
        result = edits.apply(bridge)
        report["ok"] = result.ok
        if not result.ok:
            report["error"] = str(result.errors[0])
    return json.dumps(report, indent=2, sort_keys=True)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    options = parser.parse_args(argv)
    if options.command is None:
        parser.print_help()
        return 0
    try:
        settings = load_settings()
        with Bridge(settings.host, settings.port, settings.token) as bridge:
            if options.command == "ping":
                print(f"pong from {bridge.host}:{bridge.port} in {bridge.ping() * 1000:.1f} ms")
            elif options.command == "info":
                print(json.dumps(bridge.server_info(), indent=2, sort_keys=True))
            elif options.command == "render":
                print(_topdown(bridge, options))
            elif options.command == "terrain":
                handler = {"analyze": _terrain_analyze, "find-site": _terrain_find_site, "terraform": _terrain_terraform}[options.terrain]
                print(handler(bridge, options))
            else:
                print(_heightmap(bridge, options))
    except (ConfigError, BridgeError, KeyError, ValueError) as exc:
        message = exc.args[0] if isinstance(exc, KeyError) else exc
        print(f"designer: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
