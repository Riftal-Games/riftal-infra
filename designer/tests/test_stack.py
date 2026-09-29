import subprocess
from pathlib import Path

import pytest

from designer import stack

COMPOSE_TEXT = """
services:
  designer:
    image: local-pocketmine-mp
    ports:
      - "127.0.0.1:${DESIGNER_GAME_PORT:-19134}:19132/udp"
      - "127.0.0.1:19140:19140/tcp"
    volumes:
      - designer-world:/data
      - ./plugins:/plugins
    environment:
      DESIGNBRIDGE_TOKEN: ${DESIGNBRIDGE_TOKEN}
"""


def write_compose(tmp_path: Path) -> Path:
    path = tmp_path / "compose.yaml"
    path.write_text(COMPOSE_TEXT, encoding="utf-8")
    return path


class Recorder:
    """Fakes ``subprocess.run``, recording every argv it was called with."""

    def __init__(self, *, ps_stdout: str = "", git_stdout: str = "", logs_stdout: str = "") -> None:
        self.calls: list[list[str]] = []
        self.ps_stdout, self.git_stdout, self.logs_stdout = ps_stdout, git_stdout, logs_stdout

    def __call__(self, argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        self.calls.append(list(argv))
        stdout = self.ps_stdout if "ps" in argv else self.git_stdout if argv[0] == "git" else self.logs_stdout if "logs" in argv else ""
        return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")


def test_runtime_name_defaults_env_file_and_invalid(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    assert stack.runtime_name(env={}, env_file=env_file) == "wslc"
    assert stack.runtime_name(env={"DESIGNER_RUNTIME": "docker"}, env_file=env_file) == "docker"
    env_file.write_text("DESIGNER_RUNTIME=docker\n", encoding="utf-8")
    assert stack.runtime_name(env={}, env_file=env_file) == "docker"
    with pytest.raises(stack.StackError, match="DESIGNER_RUNTIME"):
        stack.runtime_name(env={"DESIGNER_RUNTIME": "podman"}, env_file=env_file)


def test_load_service_expands_overrides_and_rejects_a_missing_service(tmp_path: Path) -> None:
    compose = write_compose(tmp_path)
    default = stack.load_service(compose, env={})
    assert default.ports == ("127.0.0.1:19134:19132/udp", "127.0.0.1:19140:19140/tcp")
    assert default.volumes[0] == "designer-world:/data"
    assert default.volumes[1] == str((tmp_path / "plugins").resolve()).replace("\\", "/") + ":/plugins"
    assert default.environment == {"DESIGNBRIDGE_TOKEN": ""}

    overridden = stack.load_service(compose, env={"DESIGNER_GAME_PORT": "19999", "DESIGNBRIDGE_TOKEN": "secret"})
    assert overridden.ports[0] == "127.0.0.1:19999:19132/udp"
    assert overridden.environment == {"DESIGNBRIDGE_TOKEN": "secret"}

    missing = tmp_path / "missing.yaml"
    missing.write_text("services:\n  other:\n    image: x\n", encoding="utf-8")
    with pytest.raises(stack.StackError, match="designer"):
        stack.load_service(missing, env={})


def test_the_real_compose_file_keeps_its_security_and_bot_defaults() -> None:
    default = stack.load_service(env={})
    assert [p for p in default.ports if p.endswith("/udp")] == ["127.0.0.1:19134:19132/udp"]
    assert [p for p in default.ports if "19140" in p] == ["127.0.0.1:19140:19140/tcp"]
    assert default.volumes[0] == "designer-world:/data"
    assert default.environment["RIFTAL_DEV_ENV"] == "1"
    args = default.environment["POCKETMINE_ARGS"].split()
    assert "--riftal-dev-bots=off" in args and "--xbox-auth=false" in args
    # PocketMine casts the value with (bool), so "false" enables crash uploads.
    assert [a for a in args if a.startswith("--auto-report.enabled")] == ["--auto-report.enabled=0"]

    overridden = stack.load_service(env={"DESIGNER_GAME_BIND": "192.168.0.10", "DESIGNER_VOLUME": "riftal_smoke_x"})
    assert [p for p in overridden.ports if "19140" in p] == ["127.0.0.1:19140:19140/tcp"]
    assert overridden.volumes[0] == "riftal_smoke_x:/data"


VOLUMES_TEXT = """
{top}services:
  designer:
    image: local-pocketmine-mp
    volumes:
      - unnamed:/a
      - external:/b
      - pinned:/c
volumes:
  unnamed:
  external:
    external: true
  pinned:
    name: ${{PINNED:-pinned-default}}
"""


def write_volumes_compose(tmp_path: Path, directory: str = "My_Stack.Dir", top: str = "") -> Path:
    path = tmp_path / directory / "compose.yaml"
    path.parent.mkdir()
    path.write_text(VOLUMES_TEXT.format(top=top), encoding="utf-8")
    return path


def test_volume_names_follow_compose_project_prefixing(tmp_path: Path) -> None:
    by_directory = stack.load_service(write_volumes_compose(tmp_path), env={})
    assert by_directory.volumes == ("my_stackdir_unnamed:/a", "external:/b", "pinned-default:/c")

    by_top_level = stack.load_service(write_volumes_compose(tmp_path, "other", "name: Top_Name\n"), env={})
    assert by_top_level.volumes[0] == "top_name_unnamed:/a"

    by_env = stack.load_service(write_volumes_compose(tmp_path, "third", "name: Top_Name\n"), env={"COMPOSE_PROJECT_NAME": "from-env"})
    assert by_env.volumes == ("from-env_unnamed:/a", "external:/b", "pinned-default:/c")


@pytest.mark.parametrize("explicit", ["Upper", "_x", "a!"])
def test_a_compose_project_name_compose_refuses_is_refused(tmp_path: Path, explicit: str) -> None:
    with pytest.raises(stack.StackError, match="COMPOSE_PROJECT_NAME"):
        stack.load_service(write_volumes_compose(tmp_path), env={"COMPOSE_PROJECT_NAME": explicit})


@pytest.mark.parametrize(("top", "expected"), [("name: Top_Name\n", "top_name"), ("", "my_stackdir")])
def test_an_empty_compose_project_name_falls_through(tmp_path: Path, top: str, expected: str) -> None:
    service = stack.load_service(write_volumes_compose(tmp_path, top=top), env={"COMPOSE_PROJECT_NAME": ""})
    assert service.volumes[0] == f"{expected}_unnamed:/a"


@pytest.mark.parametrize(
    ("directory", "top", "env", "expected"),
    [
        ("-Lead-Dir", "", {}, "lead-dir"),
        ("_x", "name: '__Top-Name'\n", {}, "top-name"),
        ("literal", "name: ''\n", {}, "literal"),
        ("dflt", "name: '${TOPV:-Via_Default}'\n", {}, "via_default"),
        ("set", "name: '${TOPV}'\n", {"TOPV": "Set_Me"}, "set_me"),
    ],
)
def test_project_name_normalizes_and_interpolates_like_compose(tmp_path: Path, directory: str, top: str, env: dict[str, str], expected: str) -> None:
    service = stack.load_service(write_volumes_compose(tmp_path, directory, top), env=env)
    assert service.volumes[0] == f"{expected}_unnamed:/a"


@pytest.mark.parametrize(
    ("top", "env", "match"),
    [
        ("name: '!!!'\n", {}, "cannot derive a compose project name"),
        ("name: '__'\n", {}, "cannot derive a compose project name"),
        ("name: '${TOPV}'\n", {}, "cannot derive a compose project name"),
        ("name: '${TOPV}'\n", {"TOPV": ""}, "cannot derive a compose project name"),
        ("name:\n", {}, "not a string"),
        ("name: 123\n", {}, "not a string"),
    ],
)
def test_a_top_level_name_compose_refuses_is_refused(tmp_path: Path, top: str, env: dict[str, str], match: str) -> None:
    with pytest.raises(stack.StackError, match=match):
        stack.load_service(write_volumes_compose(tmp_path, "fallback", top), env=env)


@pytest.mark.parametrize("name", ["${PINNED}", '""', ""])
def test_a_volume_name_that_resolves_empty_is_refused(tmp_path: Path, name: str) -> None:
    compose = write_volumes_compose(tmp_path)
    compose.write_text(compose.read_text(encoding="utf-8").replace("${PINNED:-pinned-default}", name), encoding="utf-8")
    with pytest.raises(stack.StackError, match="'pinned'.*empty"):
        stack.load_service(compose, env={})


def test_wslc_run_argv_carries_ports_volumes_env_and_image() -> None:
    service = stack.ServiceSpec(image="local-pocketmine-mp", ports=("p",), volumes=("v",), environment={"K": "V"})
    argv = stack._wslc_run_argv(service)

    assert argv[:6] == ["wslc", "run", "-d", "-i", "--name", "designer"]
    assert argv[-1] == "local-pocketmine-mp" and "--rm" not in argv
    assert "-p" in argv and "p" in argv and "-v" in argv and "v" in argv and "-e" in argv and "K=V" in argv


@pytest.mark.parametrize("runtime", ["docker", "wslc"])
def test_up_dispatches_by_runtime(monkeypatch: pytest.MonkeyPatch, runtime: str) -> None:
    recorder = Recorder()
    monkeypatch.setattr(subprocess, "run", recorder)
    stack.up(runtime)

    assert recorder.calls[0][0] == ("docker" if runtime == "docker" else "wslc")


@pytest.mark.parametrize("runtime", ["wslc", "docker"])
def test_down_sends_stop_polls_logs_removes_and_never_kills(monkeypatch: pytest.MonkeyPatch, runtime: str) -> None:
    calls: list[list[str]] = []
    stdins: list[object] = []
    seen = {"n": 0}
    def fake_run(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        calls.append(list(argv))
        stdins.append(kwargs.get("input"))
        seen["n"] += 1 if "logs" in argv else 0
        stdout = "cid123\n" if "ps" in argv else (stack.SHUTDOWN_MARKER if seen["n"] >= 3 else "still running") if "logs" in argv else ""
        return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")
    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setattr(stack.time, "sleep", lambda _seconds: None)
    stack.down(runtime, timeout=5, poll=0)
    attach = next(i for i, c in enumerate(calls) if "attach" in c)
    assert calls[attach] == (["docker", "attach", "cid123"] if runtime == "docker" else ["wslc", "attach", "designer"]) and stdins[attach] == "stop\n"
    assert seen["n"] == 3
    assert next(c for c in calls if "logs" in c) == (["docker", "compose", "--file", str(stack.COMPOSE_FILE), "logs", "designer"] if runtime == "docker" else ["wslc", "logs", "designer"])
    assert calls[-1] == (["docker", "compose", "--file", str(stack.COMPOSE_FILE), "down"] if runtime == "docker" else ["wslc", "remove", "designer"])
    assert not any("kill" in call for call in calls)


def test_wait_for_shutdown_times_out_without_the_marker() -> None:
    with pytest.raises(stack.StackError, match="Stopping other threads"):
        stack._wait_for_shutdown(lambda: "no marker here", timeout=0.05, poll=0.01)


def test_console_sends_the_line_for_both_runtimes_and_container_ref_raises_when_nothing_runs(monkeypatch: pytest.MonkeyPatch) -> None:
    recorder = Recorder(ps_stdout="cid123\n")
    monkeypatch.setattr(subprocess, "run", recorder)
    stack.console("docker", "say hello")
    stack.console("wslc", "say hello")
    assert [c for c in recorder.calls if "attach" in c] == [["docker", "attach", "cid123"], ["wslc", "attach", "designer"]]
    monkeypatch.setattr(subprocess, "run", Recorder(ps_stdout=""))
    with pytest.raises(stack.StackError, match="stack up"):
        stack.container_ref("docker")


@pytest.mark.parametrize("runtime", ["wslc", "docker"])
def test_build_image_and_build_devtools_use_the_runtime_binary(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, runtime: str) -> None:
    recorder = Recorder(git_stdout="abc1234\n")
    monkeypatch.setattr(subprocess, "run", recorder)
    stack.build_image(runtime, core_dir=tmp_path)
    assert recorder.calls[-1][0] == runtime and "GIT_HASH=abc1234" in recorder.calls[-1] and str(tmp_path) in recorder.calls[-1]
    stack.build_devtools(runtime, core_dir=tmp_path, plugins_dir=tmp_path / "plugins")
    assert recorder.calls[-1][:3] == [runtime, "run", "--rm"] and any("DevTools" in a for a in recorder.calls[-1])


def test_exec_wraps_a_timeout_as_a_stack_error(monkeypatch: pytest.MonkeyPatch) -> None:
    def raises(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired(cmd=argv, timeout=1)

    monkeypatch.setattr(subprocess, "run", raises)
    with pytest.raises(stack.StackError, match="timed out"):
        stack._exec(["wslc", "logs", "designer"], timeout=1)
