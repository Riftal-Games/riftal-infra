import subprocess
import sys
from pathlib import Path

import anyio
import pytest

from designer import config, mcp_server, tools_doc


def test_render_is_deterministic_lists_every_tool_once_and_uses_lf() -> None:
    first, second = tools_doc.render_tools_md(mcp_server.mcp), tools_doc.render_tools_md(mcp_server.mcp)
    assert first == second and "\r" not in first and first.endswith("\n")
    names = sorted(t.name for t in anyio.run(mcp_server.mcp.list_tools))
    assert [line[3:] for line in first.splitlines() if line.startswith("## ")] == names and len(names) == 19
    assert "RETURNS:" not in first and first.count("\nReturns: ") == len(names) and first.count("```json\n") == len(names)


def test_returns_line_comes_from_the_trailer_or_the_default() -> None:
    assert tools_doc.split_description("Do it.\n\n    RETURNS: a, b.\n    ") == ("Do it.", "a, b.")
    assert tools_doc.split_description("Do it.") == ("Do it.", "see the ok envelope")


def test_write_then_check_round_trips_in_lf_bytes(tmp_path: Path) -> None:
    path = tmp_path / "TOOLS.md"
    assert tools_doc.main(["--path", str(path)]) == 0
    raw = path.read_bytes()
    assert b"\r" not in raw and raw.count(b"\n") == len(tools_doc.render_tools_md(mcp_server.mcp).splitlines())
    assert tools_doc.main(["--check", "--path", str(path)]) == 0
    assert tools_doc.main(["--check", "--path", str(tmp_path / "missing.md")]) == 1


def test_check_passes_on_the_committed_file_through_the_module_entrypoint() -> None:
    assert tools_doc.main(["--check"]) == 0
    run = subprocess.run([sys.executable, "-m", "designer.tools_doc", "--check"], cwd=config.PROJECT_ROOT, capture_output=True, text=True)
    assert run.returncode == 0 and "is current" in run.stdout, run.stderr


def test_check_fails_with_exit_1_and_a_diff_after_a_docstring_changes(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    # FastMCP copies the docstring into the registered tool at import, so the copy it reads is what changes.
    tool = mcp_server.mcp._tool_manager.get_tool("fill")
    monkeypatch.setattr(tool, "description", tool.description + "\n\nRETURNS: nothing at all.")
    assert tools_doc.main(["--check"]) == 1
    out = capsys.readouterr().out
    assert "+++ rendered" in out and "-Returns: world, bounds, dry_run" in out and "+Returns: nothing at all." in out
