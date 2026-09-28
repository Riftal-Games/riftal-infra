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

    def __init__(self, stop_log: str = "", boot_log: str = "", exit_lag: int = 0) -> None:
        self.calls: list[list[str]] = []
        self.volumes: set[str] = set()
        self.exited: set[str] = set()
        self.mounts: dict[str, list[str]] = {}
        self.logs: dict[str, str] = {}
        self.tokens: list[str] = []
        self.dirty: set[str] = set()
        self.omit: set[str] = set()
        self.lag: dict[str, int] = {}
        self.level = {"db/CURRENT": b"MANIFEST-1\n", "level.dat": b"\x0a"}
        self.stop_log, self.boot_log, self.exit_lag, self.written = stop_log, boot_log, exit_lag, b""

    @staticmethod
    def id_of(name: str) -> str:
        return hashlib.sha256(name.encode()).hexdigest()[:12]

    def __call__(self, argv: list[str], stdin: bytes | None, timeout: float) -> subprocess.CompletedProcess[bytes]:
        self.calls.append(argv)
        args, out, err, code = argv[1:], b"", b"", 0
        if argv[0] == "git":
            if "status" in argv:
                out = b" M plugin.yml\n" if Path(argv[2]).name in self.dirty else b""
            else:
                out = f"{Path(argv[2]).name}-sha\n".encode()
        elif args[:2] == ["volume", "inspect"]:
            code = 0 if args[2] in self.volumes else 1
        elif args[:2] == ["volume", "create"]:
            self.volumes.add(args[2])
        elif args[:2] == ["volume", "rm"]:
            self.volumes.discard(args[2])
        elif args[:3] == ["ps", "-a", "-q"]:
            # docker's ps -q answers ids, never names.
            out = "\n".join(map(self.id_of, self.mounts)).encode()
        elif args[0] == "inspect":
            name = next((n for n in self.mounts if self.id_of(n) == args[1]), args[1])
            info = {"Name": f"/{name}", "Image": "sha256:core", "State": {"Status": "exited" if name in self.exited else "running"}}
            if name in self.lag and (left := self.lag.pop(name) - 1):
                self.lag[name] = left
            elif name in self.logs and stack.SHUTDOWN_MARKER in self.logs[name]:
                self.exited.add(name)
            info["Mounts"] = [{"Type": "volume", "Name": v} for v in self.mounts.get(name, [])]
            out = json.dumps([{k: v for k, v in info.items() if k not in self.omit}]).encode()
        elif args[:2] == ["run", "-d"]:
            name = args[args.index("--name") + 1]
            self.mounts[name], self.logs[name] = [name], self.boot_log + BOOTED
        elif args[:2] == ["run", "--rm"]:
            out, self.written = (b"", stdin or b"") if "tee" in args else (tar_of(self.level), b"")
        elif args[0] == "logs":
            out = self.logs[args[1]].encode()
        elif args[0] == "attach" and stdin == b"stop\n":
            self.logs[args[1]] += f"{self.stop_log}[Server thread/INFO]: {stack.SHUTDOWN_MARKER}\n"
            if self.exit_lag:
                self.lag[args[1]] = self.exit_lag
            else:
                self.exited.add(args[1])
        elif args[0] == "rm":
            if args[1] in self.exited:
                del self.mounts[args[1]]
            else:
                code, err = 1, b"cannot remove a running container"
        return subprocess.CompletedProcess(argv, code, stdout=out, stderr=err)

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


def test_each_build_runs_with_its_own_token(fake: FakeBridge, root: Path) -> None:
    engine = FakeEngine()
    _build(engine, fake, root)
    _build(engine, fake, root)
    runs = [next(e for e in a if e.startswith("DESIGNBRIDGE_TOKEN=")) for a in engine.calls if a[1:3] == ["run", "-d"]]
    assert runs == [f"DESIGNBRIDGE_TOKEN={t}" for t in engine.tokens] and len(set(engine.tokens)) == 2


def test_an_error_in_the_boot_log_stops_before_the_bridge_is_reached(fake: FakeBridge, root: Path) -> None:
    engine = FakeEngine(boot_log="[Server thread/CRITICAL]: Could not load plugin DesignBridge\n")
    with pytest.raises(LevelError, match="Could not load plugin DesignBridge"):
        _build(engine, fake, root)
    assert engine.tokens == [] and "rm riftal_smoke_level_zt" in engine.verbs()


def test_removal_waits_for_the_container_to_exit(fake: FakeBridge, root: Path) -> None:
    engine = FakeEngine(exit_lag=1)
    _build(engine, fake, root)
    assert "rm riftal_smoke_level_zt" in engine.verbs() and "riftal_smoke_level_zt" not in engine.mounts


def test_a_dirty_tree_marks_its_commit(fake: FakeBridge, root: Path) -> None:
    engine = FakeEngine()
    engine.dirty.add("designbridge")
    lock = json.loads(_build(engine, fake, root).read_text(encoding="utf-8"))
    assert (lock["designbridge_commit"], lock["toolkit_commit"]) == ("designbridge-sha-dirty", f"{root.name}-sha")


def test_an_inspect_without_the_image_key_is_named_and_still_stops(fake: FakeBridge, root: Path) -> None:
    engine = FakeEngine()
    engine.omit.add("Image")
    with pytest.raises(stack.StackError, match="no 'Image' key"):
        _build(engine, fake, root)
    assert "rm riftal_smoke_level_zt" in engine.verbs() and not (root / "levels" / "zt.lock.json").exists()


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
