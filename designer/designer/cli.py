"""Command-line entry point for the ``designer`` console script."""

from __future__ import annotations

import argparse
import json
import sys

from designer import __version__
from designer.bridge import Bridge, BridgeError
from designer.config import ConfigError, load_settings
from designer.world_index import KINDS, WorldIndex


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
    return parser


def run_index(options: argparse.Namespace) -> int:
    index = WorldIndex.load()
    if options.index_command == "resolve":
        try:
            print(json.dumps(index.resolve(options.name).to_json(), sort_keys=True))
        except KeyError as exc:
            print(f"designer: {exc.args[0]}", file=sys.stderr)
            return 1
        return 0
    kinds = (options.kind,) if options.kind else KINDS[1:] if options.tag else KINDS
    data = index.to_json()
    print(json.dumps({k: [e for e in data[k] if not options.tag or options.tag in e.get("tags", [])] for k in kinds}, indent=2, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    options = parser.parse_args(argv)
    if options.command is None:
        parser.print_help()
        return 0
    if options.command == "index":
        return run_index(options)
    try:
        settings = load_settings()
        with Bridge(settings.host, settings.port, settings.token) as bridge:
            if options.command == "ping":
                print(f"pong from {bridge.host}:{bridge.port} in {bridge.ping() * 1000:.1f} ms")
            else:
                print(json.dumps(bridge.server_info(), indent=2, sort_keys=True))
    except (ConfigError, BridgeError) as exc:
        print(f"designer: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
