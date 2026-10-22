import hashlib
import io
import json
import shutil
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
# Each runtime's own spelling of the verbs the fake answers in docker's; wslc's is from devtools/rig.js and dev-stack.ps1.
SPELLINGS = {
    "wslc": {"ps": ["list"], "rm": ["remove"], "volume rm": ["volume", "remove"]},
    "docker": {"ps": ["ps"], "rm": ["rm"], "volume rm": ["volume", "rm"]},
}


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

    def __init__(self, stop_log: str = "", boot_log: str = "", exit_lag: int = 0, save_lag: int = 0) -> None:
        self.calls: list[list[str]] = []
        self.booted = BOOTED
        self.save_lag = save_lag
        self.pending: dict[str, list] = {}
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
        if argv[0] != "git":
            spoken, other = SPELLINGS[argv[0]], SPELLINGS["docker" if argv[0] == "wslc" else "wslc"]
            if any(args[:len(v)] == v for v in other.values() if v not in spoken.values()):
                return subprocess.CompletedProcess(argv, 1, stdout=b"", stderr=f"{argv[0]}: unknown verb {' '.join(args[:2])}".encode())
            args = next(([*k.split(), *args[len(v):]] for k, v in spoken.items() if args[:len(v)] == v), args)
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
            self.mounts[name], self.logs[name] = [name], self.boot_log + self.booted
        elif args[:2] == ["run", "--rm"]:
            out, self.written = (b"", stdin or b"") if "tee" in args else (tar_of(self.level), b"")
        elif args[0] == "logs":
            out = self.logs[args[1]].encode()
            # The save lands save_lag reads after the stop, so a stop that reads the log once misses it.
            if args[1] in self.pending:
                self.pending[args[1]][0] -= 1
                if not self.pending[args[1]][0]:
                    self.logs[args[1]] += self.pending.pop(args[1])[1]
        elif args[0] == "attach" and stdin == b"stop\n":
            saved = f"{self.stop_log}[Server thread/INFO]: {stack.SHUTDOWN_MARKER}\n"
            if self.save_lag:
                self.pending[args[1]] = [self.save_lag, saved]
            else:
                self.logs[args[1]] += saved
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

    return level_engine.build("zt", runtime, SOURCES, root=root, runner=engine, connect=connect, index=_index(), checks_path=root / "checks.yaml", mines_config=root / "mines.yml")


@pytest.mark.parametrize("runtime", ["wslc", "docker"])
def test_build_boots_stops_and_writes_the_lock_and_manifest(fake: FakeBridge, root: Path, runtime: str) -> None:
    engine = FakeEngine()
    lock = json.loads(_build(engine, fake, root, runtime).read_text(encoding="utf-8"))
    assert {a[0] for a in engine.calls if a[0] != "git"} == {runtime}
    run = next(a for a in engine.calls if a[1:3] == ["run", "-d"])
    assert run[run.index("-p") + 1] == "127.0.0.1:19190:19140/tcp" and run.count("-p") == 1
    flags = next(a for a in run if a.startswith("POCKETMINE_ARGS=")).split()
    assert {"POCKETMINE_ARGS=--level-name=zt", "--level-type=normal", "--level-seed=7", "--xbox-auth=false", "--auto-report.enabled=0"} <= set(flags)
    assert "riftal_smoke_level_zt:/data" in run and "/src/designbridge:/plugins/DesignBridge:ro" in run
    copy_out = next(a for a in engine.calls if a[1:3] == ["run", "--rm"] and "tar" in a)
    assert copy_out[copy_out.index("-v") + 1] == "riftal_smoke_level_zt:/data:ro"
    assert f"DESIGNBRIDGE_TOKEN={engine.tokens[0]}" in run
    verbs, remove = engine.verbs(), " ".join(SPELLINGS[runtime]["rm"])
    assert verbs.index("attach riftal_smoke_level_zt") < verbs.index(f"{remove} riftal_smoke_level_zt") < verbs.index("run --rm")
    assert (lock["core_image"], lock["designbridge_commit"], lock["toolkit_commit"]) == ("sha256:core", "designbridge-sha", f"{root.name}-sha")
    tree, size, _ = read_tree(tar_of(engine.level))
    assert lock["size_bytes"] == size == 12
    assert json.loads(engine.written) == {"content_sha256": lock["content_sha256"], "tree_sha256": tree}
    assert engine.calls[-1][-1] == "/data/worlds/zt/level-manifest.json"


@pytest.mark.parametrize(("runtime", "verbs"), [
    ("wslc", ["volume inspect", "list -a", "volume remove", "volume create", "run -d"]),
    ("docker", ["volume inspect", "ps -a", "volume rm", "volume create", "run -d"]),
])
def test_an_existing_volume_is_recreated_but_one_in_use_is_refused_by_name(fake: FakeBridge, root: Path, runtime: str, verbs: list[str]) -> None:
    engine = FakeEngine()
    engine.volumes.add("riftal_smoke_level_zt")
    _build(engine, fake, root, runtime)
    assert engine.verbs()[:5] == verbs

    engine.mounts["instance"] = ["riftal_smoke_level_zt"]
    before = len(engine.calls)
    with pytest.raises(LevelError, match="mounted by instance"):
        _build(engine, fake, root, runtime)
    assert not [a for a in engine.calls[before:] if a[1] in ("run", "rm", "remove") or a[1:3] in (["volume", "rm"], ["volume", "remove"])]


def test_each_build_runs_with_its_own_token(fake: FakeBridge, root: Path) -> None:
    engine = FakeEngine()
    _build(engine, fake, root)
    _build(engine, fake, root)
    runs = [next(e for e in a if e.startswith("DESIGNBRIDGE_TOKEN=")) for a in engine.calls if a[1:3] == ["run", "-d"]]
    assert runs == [f"DESIGNBRIDGE_TOKEN={t}" for t in engine.tokens] and len(set(engine.tokens)) == 2


@pytest.mark.parametrize(("boot_log", "match"), [
    ("[Server thread/CRITICAL]: Could not load plugin DesignBridge\n", "Could not load plugin DesignBridge"),
    ("[Server thread/INFO]: pocketmine\\plugin\\PluginException: bad plugin.yml\n", "PluginException: bad plugin.yml"),
])
def test_an_error_in_the_boot_log_stops_before_the_bridge_is_reached(fake: FakeBridge, root: Path, boot_log: str, match: str) -> None:
    engine = FakeEngine(boot_log=boot_log)
    with pytest.raises(LevelError, match=match):
        _build(engine, fake, root)
    assert engine.tokens == [] and "rm riftal_smoke_level_zt" in engine.verbs()


@pytest.mark.parametrize("booted", BOOTED.splitlines(keepends=True))
def test_boot_waits_for_both_ready_lines(fake: FakeBridge, root: Path, monkeypatch: pytest.MonkeyPatch, booted: str) -> None:
    monkeypatch.setattr(level_engine, "BOOT_TIMEOUT", 1)
    engine = FakeEngine()
    engine.booted = booted
    with pytest.raises(LevelError, match="logged no"):
        _build(engine, fake, root)
    assert engine.tokens == [] and "rm riftal_smoke_level_zt" in engine.verbs()


# At a lag of 2 the first two inspects report running, and removal needs the status read, not just a wait.
@pytest.mark.parametrize("exit_lag", [1, 2])
def test_removal_waits_for_the_container_to_exit(fake: FakeBridge, root: Path, exit_lag: int) -> None:
    engine = FakeEngine(exit_lag=exit_lag)
    _build(engine, fake, root)
    assert "rm riftal_smoke_level_zt" in engine.verbs() and "riftal_smoke_level_zt" not in engine.mounts


def test_an_error_logged_with_a_late_shutdown_line_still_refuses_the_build(fake: FakeBridge, root: Path) -> None:
    engine = FakeEngine("[Server thread/ERROR]: Could not save chunk\n", save_lag=1)
    with pytest.raises(LevelError, match="Could not save chunk"):
        _build(engine, fake, root)
    assert "rm riftal_smoke_level_zt" in engine.verbs() and not (root / "levels" / "zt.lock.json").exists()


def test_the_marker_and_text_files_feed_the_content_hash(fake: FakeBridge, root: Path) -> None:
    hashes = []
    for docs in ({}, {}, {"design_npcs.json": b'{"npcs": [{"name": "guard"}]}'}, {"design_texts.json": b'{"texts": [{"text": "Mine A"}]}'}):
        engine = FakeEngine()
        engine.level.update(docs)
        hashes.append(json.loads(_build(engine, fake, root).read_text(encoding="utf-8"))["content_sha256"])
    assert hashes[0] == hashes[1] and len(set(hashes)) == 3


# The container step's python image carries no git. The host-side pytest step runs this on the runner, which has it.
@pytest.mark.skipif(shutil.which("git") is None, reason="needs a git binary, absent from the container test image")
def test_a_changed_lock_does_not_mark_the_toolkit_dirty(tmp_path: Path) -> None:
    def git(*args: str) -> None:
        subprocess.run(["git", "-C", str(tmp_path), "-c", "user.name=t", "-c", "user.email=t@t", *args], check=True, capture_output=True)

    (tmp_path / "levels").mkdir()
    (tmp_path / "levels" / "zt.lock.json").write_text("{}\n", encoding="utf-8")
    (tmp_path / "README.md").write_text("a\n", encoding="utf-8")
    git("init", "-q")
    git("add", ".")
    git("commit", "-q", "-m", "c")
    (tmp_path / "levels" / "zt.lock.json").write_text('{"seed": 8}\n', encoding="utf-8")
    (tmp_path / "levels" / "zu.lock.json").write_text("{}\n", encoding="utf-8")
    assert not level_engine.commit(level_engine.run_process, tmp_path).endswith("-dirty")
    (tmp_path / "README.md").write_text("b\n", encoding="utf-8")
    assert level_engine.commit(level_engine.run_process, tmp_path).endswith("-dirty")


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
