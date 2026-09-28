from pathlib import Path
from types import SimpleNamespace

import pytest

from designer import world_index
from tests import conftest

OK, FAILED, INTERRUPTED = pytest.ExitCode.OK, pytest.ExitCode.TESTS_FAILED, pytest.ExitCode.INTERRUPTED


def test_default_index_is_a_byte_equal_copy_outside_the_tree() -> None:
    copy = world_index.DEFAULT_PATH
    assert copy != conftest.COMMITTED_INDEX
    assert not copy.resolve().is_relative_to(conftest.TREE)
    assert copy.read_bytes() == conftest.COMMITTED_INDEX.read_bytes()


@pytest.mark.parametrize(
    ("status", "touched", "expected"),
    [
        pytest.param(OK, True, FAILED, id="green-run-that-wrote-fails"),
        pytest.param(OK, False, OK, id="green-clean-run-stays-green"),
        pytest.param(FAILED, True, FAILED, id="failed-stays-failed"),
        pytest.param(INTERRUPTED, True, INTERRUPTED, id="interrupted-stays-interrupted"),
    ],
)
def test_sessionfinish_fails_only_a_green_run_that_wrote(
    status: pytest.ExitCode, touched: bool, expected: pytest.ExitCode, monkeypatch: pytest.MonkeyPatch
) -> None:
    written = Path("/written")
    before = {Path("/kept"): (1, 1)}
    after = before | {written: (2, 2)} if touched else dict(before)
    session = SimpleNamespace(exitstatus=status, config=SimpleNamespace(stash=pytest.Stash()))
    session.config.stash[conftest.BEFORE] = before
    monkeypatch.setattr(conftest, "_tree_state", lambda root: after)
    conftest.pytest_sessionfinish(session)
    assert session.exitstatus == expected
    assert session.config.stash[conftest.TOUCHED] == ([written] if touched else [])


def test_tree_state_prunes_dot_dirs_caches_and_only_the_top_level_stack(tmp_path: Path) -> None:
    for name in (".x/f", "__pycache__/f.pyc", "stack/f", "a/__pycache__/f.pyc", "a/stack/f", ".env", "keep.txt"):
        (tmp_path / name).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / name).write_text("x")
    watched = {tmp_path, tmp_path / "a", tmp_path / "a" / "stack", tmp_path / "a" / "stack" / "f", tmp_path / ".env", tmp_path / "keep.txt"}
    assert set(conftest._tree_state(tmp_path)) == watched
