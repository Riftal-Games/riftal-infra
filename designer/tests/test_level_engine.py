import hashlib
import io
import json
import subprocess
import tarfile
from pathlib import Path

import pytest

from designer import level_engine, stack
from designer.bridge import Bridge
from designer.level import LevelError
from designer.level_engine import Sources, read_tree
from tests import test_level
from tests.fake_bridge import FakeBridge
from tests.test_level import _index

SOURCES = Sources(Path("/src/designbridge"), Path("/src/plugins"), 19190)
root = test_level.root
BOOTED = "[Server thread/INFO]: [DesignBridge] enabled, bridge target 0.0.0.0:19140\n[Server thread/INFO]: Done (3.2s)!\n"


def tar_of(files: dict[str, bytes]) -> bytes:
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w") as tar:
        for path, body in files.items():
            info = tarfile.TarInfo(f"./{path}")
            info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
    return out.getvalue()


class FakeEngine:
    """Answers the engine and git argv the build sends, holding volumes, containers and logs in memory."""

    def __init__(self, stop_log: str = "") -> None:
        self.calls: list[list[str]] = []
        self.volumes: set[str] = set()
        self.exited: set[str] = set()
        self.mounts: dict[str, list[str]] = {}
        self.logs: dict[str, str] = {}
        self.tokens: list[str] = []
        self.level = {"db/CURRENT": b"MANIFEST-1\n", "level.dat": b"\x0a"}
        self.stop_log, self.written = stop_log, b""

    def __call__(self, argv: list[str], stdin: bytes | None, timeout: float) -> subprocess.CompletedProcess[bytes]:
        self.calls.append(argv)
        args, out, code = argv[1:], b"", 0
        if argv[0] == "git":
            out = b"" if "status" in argv else f"{Path(argv[2]).name}-sha\n".encode()
        elif args[:2] == ["volume", "inspect"]:
            code = 0 if args[2] in self.volumes else 1
        elif args[:2] == ["volume", "create"]:
            self.volumes.add(args[2])
        elif args[:2] == ["volume", "rm"]:
            self.volumes.discard(args[2])
        elif args[:3] == ["ps", "-a", "-q"]:
            out = "\n".join(self.mounts).encode()
        elif args[0] == "inspect":
            info = {"Name": f"/{args[1]}", "Image": "sha256:core", "State": {"Status": "exited" if args[1] in self.exited else "running"}}
            out = json.dumps([{**info, "Mounts": [{"Type": "volume", "Name": v} for v in self.mounts.get(args[1], [])]}]).encode()
        elif args[:2] == ["run", "-d"]:
            name = args[args.index("--name") + 1]
            self.mounts[name], self.logs[name] = [name], BOOTED
        elif args[:2] == ["run", "--rm"]:
            out, self.written = (b"", stdin or b"") if "tee" in args else (tar_of(self.level), b"")
        elif args[0] == "logs":
            out = self.logs[args[1]].encode()
        elif args[0] == "attach" and stdin == b"stop\n":
            self.logs[args[1]] += f"{self.stop_log}[Server thread/INFO]: {stack.SHUTDOWN_MARKER}\n"
            self.exited.add(args[1])
        elif args[0] == "rm":
            del self.mounts[args[1]]
        return subprocess.CompletedProcess(argv, code, stdout=out, stderr=b"")

    def verbs(self) -> list[str]:
        return [" ".join(a[1:3]) for a in self.calls if a[0] != "git"]


def _build(engine: FakeEngine, fake: FakeBridge, root: Path, runtime: str = "docker") -> Path:
    def connect(port: int, token: str) -> Bridge:
        engine.tokens.append(token)
        return Bridge("127.0.0.1", fake.port, fake.token, timeout=2.0, max_retries=1)

    return level_engine.build("zt", runtime, SOURCES, root=root, runner=engine, connect=connect, index=_index(), checks_path=root / "checks.yaml")


@pytest.mark.parametrize("runtime", ["wslc", "docker"])
def test_build_boots_stops_and_writes_the_lock_and_manifest(fake: FakeBridge, root: Path, runtime: str) -> None:
    engine = FakeEngine()
    lock = json.loads(_build(engine, fake, root, runtime).read_text(encoding="utf-8"))
    assert {a[0] for a in engine.calls if a[0] != "git"} == {runtime}
    run = next(a for a in engine.calls if a[1:3] == ["run", "-d"])
    assert run[run.index("-p") + 1] == "127.0.0.1:19190:19140/tcp" and run.count("-p") == 1
    flags = next(a for a in run if a.startswith("POCKETMINE_ARGS=")).split()
    assert {"POCKETMINE_ARGS=--level-name=zt", "--level-type=normal", "--level-seed=7", "--auto-report.enabled=0"} <= set(flags)
    assert "riftal_smoke_level_zt:/data" in run and "/src/designbridge:/plugins/DesignBridge:ro" in run
    assert f"DESIGNBRIDGE_TOKEN={engine.tokens[0]}" in run
    verbs = engine.verbs()
    assert verbs.index("attach riftal_smoke_level_zt") < verbs.index("rm riftal_smoke_level_zt") < verbs.index("run --rm")
    assert (lock["core_image"], lock["designbridge_commit"], lock["toolkit_commit"]) == ("sha256:core", "designbridge-sha", f"{root.name}-sha")
    tree, size, _ = read_tree(tar_of(engine.level))
    assert lock["size_bytes"] == size == 12
    assert json.loads(engine.written) == {"content_sha256": lock["content_sha256"], "tree_sha256": tree}
    assert engine.calls[-1][-1] == "/data/worlds/zt/level-manifest.json"


def test_an_existing_volume_is_recreated_but_one_in_use_is_refused_by_name(fake: FakeBridge, root: Path) -> None:
    engine = FakeEngine()
    engine.volumes.add("riftal_smoke_level_zt")
    _build(engine, fake, root)
    assert engine.verbs()[:4] == ["volume inspect", "ps -a", "volume rm", "volume create"]

    engine.mounts["instance"] = ["riftal_smoke_level_zt"]
    before = len(engine.calls)
    with pytest.raises(LevelError, match="mounted by instance"):
        _build(engine, fake, root)
    assert not [a for a in engine.calls[before:] if a[1] in ("run", "rm") or a[1:3] == ["volume", "rm"]]


@pytest.mark.parametrize(("stop_log", "findings", "match"), [
    ("", [{"kind": "entity", "chunk": [0, 0], "save_id": "Item"}], "1 item or entity finding"),
    ("[Server thread/ERROR]: Could not save chunk\n", [], "Could not save chunk"),
])
def test_a_refused_build_still_stops_cleanly_and_writes_nothing(fake: FakeBridge, root: Path, stop_log: str, findings: list, match: str) -> None:
    fake.scan_findings, engine = findings, FakeEngine(stop_log)
    with pytest.raises(LevelError, match=match):
        _build(engine, fake, root)
    assert "rm riftal_smoke_level_zt" in engine.verbs() and "tee" not in engine.calls[-1]
    assert not (root / "levels" / "zt.lock.json").exists()


@pytest.mark.parametrize("zone", ["overworld", "player_hub", "backups", "Lumber"])
def test_a_refused_name_makes_no_engine_call(zone: str) -> None:
    engine = FakeEngine()
    with pytest.raises(LevelError):
        level_engine.build(zone, "wslc", SOURCES, runner=engine)
    assert engine.calls == []


def test_the_tree_hash_is_sha256sum_output_without_the_manifest() -> None:
    files = {"level.dat": b"a", "db/000005.ldb": b"bb", "design_npcs.json": b'{"npcs": []}'}
    tree, size, docs = read_tree(tar_of({**files, "level-manifest.json": b"{}"}))
    listing = "".join(f"{hashlib.sha256(files[p]).hexdigest()}  {p}\n" for p in sorted(files))
    assert tree == hashlib.sha256(listing.encode()).hexdigest()
    assert (size, docs) == (15, {"design_npcs.json": {"npcs": []}})


def test_the_cli_refuses_a_missing_devtools_phar(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    from designer.cli import main

    assert main(["level", "build", "zt", "--designbridge", str(tmp_path), "--plugins", str(tmp_path)]) == 1
    assert "DevTools.phar" in capsys.readouterr().err
