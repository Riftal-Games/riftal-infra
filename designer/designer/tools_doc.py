"""``designer/TOOLS.md`` rendered from the registered MCP tools, and the check that keeps it current.

``python -m designer.tools_doc`` writes the file. ``--check`` writes nothing and exits 1
with a unified diff when the committed file differs from what the tools render, which
is the CI gate that stops a docstring or a signature changing without the document.
"""

from __future__ import annotations

import argparse
import difflib
import inspect
import json
import sys
from pathlib import Path

import anyio
from mcp.server.fastmcp import FastMCP

from designer import config, mcp_server

TOOLS_MD = config.PROJECT_ROOT / "TOOLS.md"
RETURNS_TAG = "RETURNS:"
HEADER = (
    "# Designer MCP tools\n\n"
    "Rendered by `python -m designer.tools_doc`; edit the docstrings in designer/designer/mcp_server.py, not this file.\n"
    "Every tool answers `{\"ok\": true, ...}` with the keys on its `Returns` line; a call that stops partway merges those\n"
    "same keys with `{\"ok\": false, \"error\": ..., \"code\": ...}` rather than replacing them.\n"
)


def split_description(doc: str, name: str) -> tuple[str, str]:
    """The description without its ``RETURNS:`` trailer, and the trailer's text; a tool without one is an error."""
    lines = inspect.cleandoc(doc).splitlines()
    trailers = [line[len(RETURNS_TAG):].strip() for line in lines if line.startswith(RETURNS_TAG)]
    if not trailers:
        raise ValueError(f"tool {name!r} has no {RETURNS_TAG} trailer in its docstring")
    return "\n".join(line for line in lines if not line.startswith(RETURNS_TAG)).strip(), trailers[-1]


def render_tools_md(mcp: FastMCP) -> str:
    """The whole document, LF only, one section per tool in name order."""
    sections = []
    for tool in sorted(anyio.run(mcp.list_tools), key=lambda t: t.name):
        description, returns = split_description(tool.description or "", tool.name)
        schema = json.dumps(tool.inputSchema, sort_keys=True)
        sections.append(f"## {tool.name}\n\n{description}\n\n```json\n{schema}\n```\nReturns: {returns}\n")
    return "\n".join([HEADER, *sections])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m designer.tools_doc", description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="exit 1 with a diff when the file is stale, writing nothing")
    parser.add_argument("--path", type=Path, default=TOOLS_MD, help=f"the file to write or check (default {TOOLS_MD})")
    args = parser.parse_args(argv)
    rendered = render_tools_md(mcp_server.mcp)
    if not args.check:
        args.path.write_bytes(rendered.encode("utf-8"))
        print(f"wrote {args.path}")
        return 0
    current = args.path.read_bytes().decode("utf-8") if args.path.is_file() else ""
    if current == rendered:
        print(f"{args.path} is current")
        return 0
    sys.stdout.writelines(difflib.unified_diff(current.splitlines(True), rendered.splitlines(True), str(args.path), "rendered"))
    print(f"{args.path} is stale; run python -m designer.tools_doc")
    return 1


if __name__ == "__main__":
    sys.exit(main())
