from pathlib import Path

import pytest

from designer import config, persist


@pytest.fixture(autouse=True)
def _reports_dir(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(config, "REPORTS_DIR", tmp_path / "reports")


def test_load_with_no_file_is_empty() -> None:
    assert persist.load() == {}


def test_record_then_get_round_trips_and_survives_a_fresh_load() -> None:
    persist.record("checkpoint", "design", (1, 64, -2), "minecraft:diamond_block")
    assert persist.get("checkpoint") == {"world": "design", "pos": [1, 64, -2], "block": "minecraft:diamond_block"}
    # A fresh call reads the file back rather than any in-memory state, which is the point:
    # persist_verify must work from a process started after the container was replaced.
    assert persist.load()["checkpoint"]["pos"] == [1, 64, -2]


def test_get_of_an_unknown_marker_raises_key_error() -> None:
    with pytest.raises(KeyError, match="no persist_mark recorded as 'ghost'"):
        persist.get("ghost")


def test_record_twice_overwrites_the_same_marker_and_keeps_others(tmp_path: Path) -> None:
    persist.record("a", "design", (0, 64, 0), "minecraft:stone")
    persist.record("b", "design", (1, 64, 0), "minecraft:stone")
    persist.record("a", "design", (0, 65, 0), "minecraft:glass")
    assert persist.get("a") == {"world": "design", "pos": [0, 65, 0], "block": "minecraft:glass"}
    assert persist.get("b")["pos"] == [1, 64, 0]
    assert not (config.REPORTS_DIR / "persist-markers.json.tmp").exists()


def test_manifest_path_is_under_reports_dir() -> None:
    assert persist.manifest_path() == config.REPORTS_DIR / "persist-markers.json"
