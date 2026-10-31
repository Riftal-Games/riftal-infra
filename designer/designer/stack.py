"""Container lifecycle for the designer stack.

The one module that knows ``wslc`` exists: it reads ``compose.yaml``'s
``designer`` service and hands it to ``docker compose``, or translates it
into ``wslc run`` flags, since ``wslc`` has no compose verb of its own.
``DESIGNER_RUNTIME=docker`` picks the former; the local default is ``wslc``.
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

import yaml

from designer.config import ENV_FILE, PROJECT_ROOT, read_env_file

STACK_DIR = PROJECT_ROOT / "stack"
COMPOSE_FILE = STACK_DIR / "compose.yaml"
SERVICE = "designer"
CONTAINER_NAME = "designer"
IMAGE = "local-pocketmine-mp"
TOOL_MEMORY = "1G"
TOOL_CPUS = "1"
DEFAULT_CORE_DIR = STACK_DIR.parent.parent.parent / "pmmp-core"

RUNTIMES = ("wslc", "docker")
DEFAULT_TIMEOUT = 30
# The first PHP build compiles from source; later builds reuse that layer.
BUILD_TIMEOUT = 3600
DEVTOOLS_TIMEOUT = 120
STOP_TIMEOUT = 60
# Last line PocketMine logs before the process exits; see stack/README.md.
SHUTDOWN_MARKER = "Stopping other threads"

_VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")
_PROJECT_RE = re.compile(r"[a-z0-9][a-z0-9_-]*")


class StackError(Exception):
    """A stack command failed, timed out, or ``compose.yaml`` is unreadable."""


@dataclass(frozen=True)
class ServiceSpec:
    image: str
    ports: tuple[str, ...]
    volumes: tuple[str, ...]
    environment: dict[str, str]


def runtime_name(env: Mapping[str, str] | None = None, env_file: Path | None = None) -> str:
    """Resolve ``DESIGNER_RUNTIME`` the same way ``config.load_settings`` resolves settings."""
    if env is None:
        env = os.environ
    if env_file is None:
        env_file = ENV_FILE
    file_values = read_env_file(env_file)
    name = env.get("DESIGNER_RUNTIME") or file_values.get("DESIGNER_RUNTIME") or "wslc"
    if name not in RUNTIMES:
        raise StackError(f"DESIGNER_RUNTIME must be one of {RUNTIMES}, got {name!r}.")
    return name


def _expand(value: object, env: Mapping[str, str]) -> str:
    def repl(match: re.Match[str]) -> str:
        name, default = match.group(1), match.group(2)
        return env.get(name) or default or ""

    return _VAR_RE.sub(repl, str(value))


def _project_name(document: Mapping[str, object], compose_file: Path, env: Mapping[str, str]) -> str:
    """Compose's project name: a non-empty ``COMPOSE_PROJECT_NAME`` taken as
    given and refused unless it is lowercase letters, digits, ``_`` and ``-``
    starting with a letter or digit, else the interpolated top-level
    ``name:``, else the compose file's directory name, both normalized.

    Only an absent or literal empty ``name:`` falls back to the directory.
    Compose refuses a ``name:`` that is not a string with ``name must be a
    string``, and one that interpolates or normalizes to empty with ``project
    name must not be empty``."""
    explicit = env.get("COMPOSE_PROJECT_NAME")
    if explicit:
        if not _PROJECT_RE.fullmatch(explicit):
            raise StackError(f"COMPOSE_PROJECT_NAME {explicit!r} is not a valid compose project name.")
        return explicit
    top = document.get("name", "")
    if not isinstance(top, str):
        raise StackError(f"the top-level name {top!r} is not a string; docker compose refuses it too.")
    raw = _expand(top, env) if top else compose_file.resolve().parent.name
    project = re.sub(r"[^a-z0-9_-]", "", raw.lower()).lstrip("_-")
    if not project:
        raise StackError(f"cannot derive a compose project name from {raw!r}.")
    return project


def _volume_names(declared: Mapping[str, object], project: str, env: Mapping[str, str]) -> dict[str, str]:
    """Map each top-level volume key to the volume compose would mount. Compose
    refuses a null ``name:`` with ``must be a string`` and one that resolves
    empty with ``invalid volume name or ID: value is empty``, so either is
    refused here rather than mounted."""
    names = {}
    for key, value in declared.items():
        value = value or {}
        if "name" in value:
            name = _expand(value["name"] or "", env)
            if not name:
                raise StackError(f"volume {key!r} has a name that resolves empty; docker compose refuses it too.")
        elif value.get("external"):
            name = key
        else:
            name = f"{project}_{key}"
        names[key] = name
    return names


def _resolve_volume(spec: str, base: Path, names: Mapping[str, str]) -> str:
    """A bare name (``designer-world``) is a named volume, mapped to the name
    compose gives it; a ``./`` or ``../`` host resolves relative to the compose
    file, same as compose."""
    host, _, remainder = spec.partition(":")
    if host.startswith("./") or host.startswith("../"):
        host = str((base / host).resolve()).replace("\\", "/")
    else:
        host = names.get(host, host)
    return f"{host}:{remainder}"


def load_service(compose_file: Path = COMPOSE_FILE, env: Mapping[str, str] | None = None) -> ServiceSpec:
    """Read the ``designer`` service out of ``compose.yaml``, expanding ``${VAR:-default}``."""
    if env is None:
        env = os.environ
    try:
        document = yaml.safe_load(compose_file.read_text(encoding="utf-8"))
        service = document["services"][SERVICE]
        declared = document.get("volumes") or {}
        names = _volume_names(declared, _project_name(document, compose_file, env), env)
    except (OSError, yaml.YAMLError, KeyError, TypeError, AttributeError) as exc:
        raise StackError(f"cannot read the {SERVICE!r} service from {compose_file}: {exc}") from exc
    base = compose_file.parent
    ports = tuple(_expand(p, env) for p in service.get("ports", []))
    volumes = tuple(_resolve_volume(_expand(v, env), base, names) for v in service.get("volumes", []))
    environment = {k: _expand(v, env) for k, v in (service.get("environment") or {}).items()}
    return ServiceSpec(image=service["image"], ports=ports, volumes=volumes, environment=environment)


def _exec(argv: Sequence[str], *, timeout: float = DEFAULT_TIMEOUT, input_text: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(list(argv), input=input_text, text=True, capture_output=True, timeout=timeout, check=check)
    except subprocess.TimeoutExpired as exc:
        raise StackError(f"timed out after {timeout}s: {' '.join(argv)}") from exc
    except subprocess.CalledProcessError as exc:
        raise StackError(f"{' '.join(argv)} failed: {exc.stderr.strip()}") from exc
    except FileNotFoundError as exc:
        raise StackError(f"{argv[0]} not found; is it on PATH?") from exc


def _binary(runtime: str) -> str:
    return "docker" if runtime == "docker" else "wslc"


def _compose_argv(*args: str) -> list[str]:
    return ["docker", "compose", "--file", str(COMPOSE_FILE), *args]


def _wslc_run_argv(service: ServiceSpec) -> list[str]:
    argv = ["wslc", "run", "-d", "-i", "--name", CONTAINER_NAME]
    for port in service.ports:
        argv += ["-p", port]
    for volume in service.volumes:
        argv += ["-v", volume]
    for key, value in service.environment.items():
        argv += ["-e", f"{key}={value}"]
    argv.append(service.image)
    return argv


def container_ref(runtime: str) -> str:
    if runtime != "docker":
        return CONTAINER_NAME
    ref = _exec(_compose_argv("ps", "-q", SERVICE)).stdout.strip()
    if not ref:
        raise StackError("no running designer container; run 'designer stack up' first")
    return ref


def up(runtime: str) -> None:
    service = load_service()
    if runtime == "docker":
        _exec(_compose_argv("up", "-d"))
        return
    _exec(_wslc_run_argv(service))


def logs(runtime: str) -> str:
    argv = _compose_argv("logs", SERVICE) if runtime == "docker" else ["wslc", "logs", CONTAINER_NAME]
    return _exec(argv).stdout


def console(runtime: str, line: str) -> None:
    _exec([_binary(runtime), "attach", container_ref(runtime)], input_text=f"{line}\n", check=False)


def _wait_for_shutdown(read_logs: Callable[[], str], *, timeout: float = STOP_TIMEOUT, poll: float = 0.5) -> None:
    deadline = time.monotonic() + timeout
    while True:
        if SHUTDOWN_MARKER in read_logs():
            return
        if time.monotonic() >= deadline:
            raise StackError(f"no {SHUTDOWN_MARKER!r} in the log within {timeout}s; the world may still be writing")
        time.sleep(poll)


def down(runtime: str, *, timeout: float = STOP_TIMEOUT, poll: float = 0.5) -> None:
    container = container_ref(runtime)
    _exec([_binary(runtime), "attach", container], input_text="stop\n", check=False)
    _wait_for_shutdown(lambda: logs(runtime), timeout=timeout, poll=poll)
    _exec(_compose_argv("down") if runtime == "docker" else ["wslc", "remove", CONTAINER_NAME])


def build_image(runtime: str, core_dir: Path | None = None) -> None:
    core_dir = core_dir or DEFAULT_CORE_DIR
    git_hash = _exec(["git", "-C", str(core_dir), "rev-parse", "HEAD"]).stdout.strip()
    argv = [_binary(runtime), "build", "-f", str(core_dir / "docker" / "Dockerfile"), "-t", IMAGE, "--build-arg", f"GIT_HASH={git_hash}", str(core_dir)]
    _exec(argv, timeout=BUILD_TIMEOUT)


def build_devtools(runtime: str, core_dir: Path | None = None, plugins_dir: Path | None = None) -> None:
    core_dir = core_dir or DEFAULT_CORE_DIR
    plugins_dir = plugins_dir or (STACK_DIR / "plugins")
    devtools_src = core_dir / "tests" / "plugins" / "DevTools"
    argv = [
        _binary(runtime), "run", "--rm", "--memory", TOOL_MEMORY, "--cpus", TOOL_CPUS, "-v", f"{devtools_src}:/src:ro", "-v", f"{plugins_dir}:/out", IMAGE,
        "php", "-dphar.readonly=0", "/src/src/ConsoleScript.php", "--make", "src,plugin.yml,resources,stub.php",
        "--relative", "/src", "--stub", "stub.php", "--out", "/out/DevTools.phar",
    ]
    _exec(argv, timeout=DEVTOOLS_TIMEOUT)
