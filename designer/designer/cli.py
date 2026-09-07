"""Command-line entry point for the ``designer`` console script."""

from __future__ import annotations

import argparse
import json
import sys

from designer import __version__
from designer.bridge import Bridge, BridgeError
from designer.config import ConfigError, load_settings
from designer.palettes import load_palettes
from designer.region import Bounds2D, Heightmap, fetch_heightmap
from designer.render import Marker, ascii_heightmap, markers_from_index, summary, topdown_png
from designer.world_index import WorldIndex


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
    return parser


def _resolve_at(index: WorldIndex, ref: str, world: str | None) -> tuple[str, tuple[int, int]]:
    entry = None
    if "," not in ref:
        try:
            entry = index.resolve(ref)
        except KeyError:
            fallback = index.locations_tagged(ref) if ref == "spawn" else []
            tagged = [l for l in fallback if l.world == (world or index.default_world)]
            if not tagged:
                raise
            entry = tagged[0]
    x, _, z = index.resolve_pos(ref if entry is None else entry.name)
    return world or (index.default_world if entry is None else entry.world), (x, z)


def _fetch(bridge: Bridge, options: argparse.Namespace) -> tuple[Heightmap, list[Marker]]:
    index = WorldIndex.load()
    world, center = _resolve_at(index, options.at, options.world)
    bounds = Bounds2D.from_center(center, (options.size, options.size))
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
            else:
                print(_heightmap(bridge, options))
    except (ConfigError, BridgeError, KeyError, ValueError) as exc:
        message = exc.args[0] if isinstance(exc, KeyError) else exc
        print(f"designer: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
