"""Command-line entry point for the ``designer`` console script."""

from __future__ import annotations

import argparse
import json
import sys

from designer import __version__
from designer.bridge import Bridge, BridgeError
from designer.config import ConfigError, load_settings


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
    return parser


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
            else:
                print(json.dumps(bridge.server_info(), indent=2, sort_keys=True))
    except (ConfigError, BridgeError) as exc:
        print(f"designer: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
