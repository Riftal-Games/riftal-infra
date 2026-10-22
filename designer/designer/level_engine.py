"""The throwaway server a zone level is built on (ADR 009 item 2), under ``wslc`` or ``docker``.

Only the bridge port is published, on loopback: nothing joins a build, and the server runs in offline mode.
"""

from __future__ import annotations

import hashlib
import io
import json
import re
import secrets
import subprocess
import tarfile
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from designer import checks as checks_mod
from designer import stack
from designer.bridge import Bridge
from designer.config import PROJECT_ROOT
from designer.level import (
    LevelError, Saved, build_level, check_index, check_mine_gate, check_reset_states, load_recipe, mines_config_path,
)
from designer.world_index import WorldIndex

PREFIX = "riftal_smoke_level_"
MANIFEST = "level-manifest.json"
# 19140 is the designer stack's bridge, 19142 the dev stack's relay and 19143 the designer stack's, so a build runs beside all of them.
DEFAULT_BRIDGE_PORT = 19144
BOOT_TIMEOUT = 300
READY = ("[DesignBridge] enabled, bridge target", "Done (")
FAILED = re.compile(r"/(ERROR|CRITICAL|EMERGENCY|ALERT)\]|Exception")
DOCS = ("design_npcs.json", "design_texts.json")
VOLUME_ABSENT = re.compile(r"no such volume|volume\b.*\b(not found|does not exist)", re.IGNORECASE)

Runner = Callable[[list[str], "bytes | None", float], "subprocess.CompletedProcess[bytes]"]


def run_process(argv: list[str], stdin: bytes | None, timeout: float) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(argv, input=stdin, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise LevelError(f"timed out after {timeout}s: {' '.join(argv[:3])}") from exc
    except FileNotFoundError as exc:
        raise LevelError(f"{argv[0]} not found; is it on PATH?") from exc


DOCKER_VERBS = {("volume", "remove"): ("volume", "rm"), ("list",): ("ps",), ("remove",): ("rm",)}


def docker_spelling(args: tuple[str, ...]) -> tuple[str, ...]:
    for verb, spelled in DOCKER_VERBS.items():
        if args[:len(verb)] == verb:
            return (*spelled, *args[len(verb):])
    return args


@dataclass(frozen=True)
class Sources:
    designbridge: Path
    plugins: Path
    bridge_port: int = DEFAULT_BRIDGE_PORT


@dataclass(frozen=True)
class Engine:
    """Verbs are given in ``wslc``'s spelling and translated for ``docker``, as ``devtools/rig.js`` does.

    ``wslc`` spells ``list``, ``remove`` and ``volume remove`` what ``docker`` spells ``ps``, ``rm``
    and ``volume rm``. No wslc transcript has yet shown its ``volume inspect``, which is sent unchanged.
    """

    runtime: str
    runner: Runner = run_process

    def __call__(self, *args: str, stdin: bytes | None = None, timeout: float = stack.DEFAULT_TIMEOUT, check: bool = True) -> subprocess.CompletedProcess[bytes]:
        argv = ["docker", *docker_spelling(args)] if self.runtime == "docker" else ["wslc", *args]
        done = self.runner(argv, stdin, timeout)
        if check and done.returncode != 0:
            # Only the verb, since a run's arguments carry the bridge token.
            raise LevelError(f"{' '.join(argv[:3])} failed: {done.stderr.decode(errors='replace').strip()}")
        return done

    def text(self, *args: str) -> str:
        done = self(*args)
        return (done.stdout + done.stderr).decode(errors="replace")

    def inspect(self, ref: str) -> dict[str, Any]:
        doc = json.loads(self.text("inspect", ref))
        return doc[0] if isinstance(doc, list) else doc

    def field(self, ref: str, key: str) -> Any:
        info = self.inspect(ref)
        if key not in info:
            raise stack.StackError(f"{self.runtime} inspect {ref} has no {key!r} key, which the build reads")
        return info[key]


def fresh_volume(engine: Engine, volume: str) -> None:
    """Create ``volume`` empty, refusing with every container that mounts it before anything is removed.

    A failed ``volume inspect`` means the volume is absent only when the engine says so; any other
    failure, a hung or missing engine for one, leaves the volume's state unknown and refuses.
    """
    probe = engine("volume", "inspect", volume, check=False)
    if probe.returncode != 0 and not VOLUME_ABSENT.search((probe.stdout + probe.stderr).decode(errors="replace")):
        raise LevelError(f"cannot tell whether volume {volume} exists: {(probe.stderr or probe.stdout).decode(errors='replace').strip()}")
    if probe.returncode == 0:
        users = []
        for ref in engine.text("list", "-a", "-q").split():
            info = engine.inspect(ref)
            if any(volume in (m.get("Name"), m.get("Source")) for m in info.get("Mounts") or []):
                users.append(str(info.get("Name") or ref).lstrip("/"))
        if users:
            raise LevelError(f"volume {volume} is mounted by {', '.join(users)}; stop and remove them, then rebuild")
        engine("volume", "remove", volume)
    engine("volume", "create", volume)


def run_args(zone: str, generator: str, seed: int, token: str, sources: Sources) -> list[str]:
    name = PREFIX + zone
    flags = f"--level-name={zone} --level-type={generator} --level-seed={seed} --xbox-auth=false --auto-report.enabled=0"
    return [
        "run", "-d", "-i", "--name", name, "-p", f"127.0.0.1:{sources.bridge_port}:19140/tcp",
        "-v", f"{name}:/data", "-v", f"{sources.plugins.as_posix()}:/plugins",
        "-v", f"{sources.designbridge.as_posix()}:/plugins/DesignBridge:ro",
        "-e", f"DESIGNBRIDGE_TOKEN={token}", "-e", f"POCKETMINE_ARGS={flags}", stack.IMAGE,
    ]


def _clean(name: str, log: str) -> str:
    if bad := next((line.strip() for line in log.splitlines() if FAILED.search(line)), None):
        raise LevelError(f"{name} logged: {bad}")
    return log


def _until(done: Callable[[], Any], timeout: float, what: str) -> Any:
    deadline = time.monotonic() + timeout
    while not (result := done()):
        if time.monotonic() >= deadline:
            raise LevelError(f"{what} within {timeout}s")
        time.sleep(0.5)
    return result


def stop(engine: Engine, name: str) -> str:
    """``stop`` on stdin, the shutdown line, then removal once the engine reports an exit; answers the log.

    An error line does not cut the wait short, since the shutdown line is the save.
    """
    engine("attach", name, stdin=b"stop\n", check=False, timeout=stack.STOP_TIMEOUT)

    def saved() -> str:
        log = engine.text("logs", name)
        return log if stack.SHUTDOWN_MARKER in log else ""

    def exited() -> bool:
        state = (info := engine.inspect(name)).get("State", info)
        return str(state.get("Status") if isinstance(state, dict) else state).lower() == "exited"

    log = _until(saved, stack.STOP_TIMEOUT, f"{name} logged no shutdown line")
    _until(exited, stack.STOP_TIMEOUT, f"{name} logged its shutdown line and is left in place, since it has not exited")
    engine("remove", name)
    return log


def read_tree(data: bytes) -> tuple[str, int, dict[str, Any]]:
    """The tree hash, the uncompressed size and the marker and text files of a tar of the level folder.

    The tree hash is sha256 over ``sha256sum``'s output for every regular file but the manifest,
    as ``./``-less paths sorted bytewise, so a shell can recompute it from the folder alone.
    """
    files, docs = {}, {}
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        for member in tar:
            path = member.name.removeprefix("./")
            if member.isfile() and path != MANIFEST and (reader := tar.extractfile(member)):
                files[path] = body = reader.read()
                if path in DOCS:
                    docs[path] = json.loads(body)
    lines = "".join(f"{hashlib.sha256(files[p]).hexdigest()}  {p}\n" for p in sorted(files, key=str.encode))
    return hashlib.sha256(lines.encode()).hexdigest(), sum(map(len, files.values())), docs


def commit(runner: Runner, path: Path) -> str:
    """``HEAD`` of ``path``'s repository, ``-dirty`` when anything under ``path`` differs but a lock, which a build writes itself."""
    head = runner(["git", "-C", str(path), "rev-parse", "HEAD"], None, stack.DEFAULT_TIMEOUT)
    status = runner(["git", "-C", str(path), "status", "--porcelain", "--", ".", ":(exclude)levels/*.lock.json"], None, stack.DEFAULT_TIMEOUT)
    if head.returncode != 0 or status.returncode != 0:
        raise LevelError(f"cannot read the commit of {path}: {(head.stderr + status.stderr).decode(errors='replace').strip()}")
    return head.stdout.decode().strip() + ("-dirty" if status.stdout.strip() else "")


def build(
    zone: str, runtime: str, sources: Sources, *, root: Path = PROJECT_ROOT, runner: Runner = run_process,
    connect: Callable[[int, str], Bridge] | None = None, index: WorldIndex | None = None, checks_path: Path | None = None,
    mines_config: Path | None = None,
) -> Path:
    """Build ``zone`` on a fresh volume and return its lock; recipe, name, index and mine gate are refused before any engine call."""
    recipe = load_recipe(zone, root)
    index = WorldIndex.load() if index is None else index
    check_index(recipe, index)
    specs = checks_mod.load_checks(checks_path)
    check_mine_gate(recipe, specs, mines_config_path() if mines_config is None else mines_config, root)
    check_reset_states(recipe, root)
    engine, name, token = Engine(runtime, runner), PREFIX + zone, secrets.token_urlsafe(24)
    fresh_volume(engine, name)
    engine(*run_args(zone, recipe.generator, recipe.seed, token, sources))
    state: dict[str, Any] = {"stopped": False}

    def after_stop() -> Saved:
        image = str(engine.field(name, "Image"))
        state["stopped"] = True
        _clean(name, stop(engine, name))
        tar = engine("run", "--rm", "-v", f"{name}:/data:ro", stack.IMAGE, "tar", "-C", f"/data/worlds/{zone}", "-cf", "-", ".", timeout=BOOT_TIMEOUT)
        state["tree"], size, docs = read_tree(tar.stdout)
        return Saved(image, commit(runner, sources.designbridge), commit(runner, root), size, *(docs.get(d) for d in DOCS))

    try:
        _until(lambda: all(map(_clean(name, engine.text("logs", name)).__contains__, READY)), BOOT_TIMEOUT, f"{name} logged no {READY}")
        with (connect or (lambda port, key: Bridge("127.0.0.1", port, key)))(sources.bridge_port, token) as bridge:
            lock_path = build_level(bridge, zone, after_stop, root=root, index=index, checks_path=checks_path, mines_config=mines_config)
    finally:
        if not state["stopped"]:
            stop(engine, name)
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    manifest = json.dumps({"content_sha256": lock["content_sha256"], "tree_sha256": state["tree"]}, indent=2, sort_keys=True) + "\n"
    # tee rather than a shell redirect, so no argument is ever parsed by a shell.
    engine("run", "--rm", "-i", "-v", f"{name}:/data", stack.IMAGE, "tee", f"/data/worlds/{zone}/{MANIFEST}", stdin=manifest.encode())
    return lock_path
