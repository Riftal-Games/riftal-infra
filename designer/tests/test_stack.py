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
      DESIGNBRIDGE_TOKEN: ${DESIGNBRIDGE_TOKEN:-local-dev-only}
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
    assert default.environment == {"DESIGNBRIDGE_TOKEN": "local-dev-only"}

    overridden = stack.load_service(compose, env={"DESIGNER_GAME_PORT": "19999", "DESIGNBRIDGE_TOKEN": "secret"})
    assert overridden.ports[0] == "127.0.0.1:19999:19132/udp"
    assert overridden.environment == {"DESIGNBRIDGE_TOKEN": "secret"}

    missing = tmp_path / "missing.yaml"
    missing.write_text("services:\n  other:\n    image: x\n", encoding="utf-8")
    with pytest.raises(stack.StackError, match="designer"):
        stack.load_service(missing, env={})


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


def test_down_polls_for_the_shutdown_marker_then_removes_and_never_kills(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []
    seen = {"n": 0}

    def fake_run(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        calls.append(list(argv))
        if "logs" in argv:
            seen["n"] += 1
            body = stack.SHUTDOWN_MARKER if seen["n"] >= 3 else "still running"
            return subprocess.CompletedProcess(argv, 0, stdout=body, stderr="")
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setattr(stack.time, "sleep", lambda _seconds: None)
    stack.down("wslc", timeout=5, poll=0)

    assert seen["n"] == 3
    assert calls[0] == ["wslc", "attach", "designer"]
    assert calls[-1] == ["wslc", "remove", "designer"]
    assert not any("kill" in call for call in calls)


def test_wait_for_shutdown_times_out_without_the_marker() -> None:
    with pytest.raises(stack.StackError, match="Stopping other threads"):
        stack._wait_for_shutdown(lambda: "no marker here", timeout=0.05, poll=0.01)


def test_console_sends_the_line_and_container_ref_raises_when_nothing_runs(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(subprocess, "run", Recorder(ps_stdout="cid123\n"))
    stack.console("docker", "say hello")

    monkeypatch.setattr(subprocess, "run", Recorder(ps_stdout=""))
    with pytest.raises(stack.StackError, match="stack up"):
        stack.container_ref("docker")


def test_build_image_and_build_devtools_use_the_runtime_binary(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    recorder = Recorder(git_stdout="abc1234\n")
    monkeypatch.setattr(subprocess, "run", recorder)
    stack.build_image("wslc", core_dir=tmp_path)
    image_call = recorder.calls[-1]
    assert image_call[0] == "wslc" and "GIT_HASH=abc1234" in image_call and str(tmp_path) in image_call

    stack.build_devtools("docker", core_dir=tmp_path, plugins_dir=tmp_path / "plugins")
    devtools_call = recorder.calls[-1]
    assert devtools_call[:3] == ["docker", "run", "--rm"] and any("DevTools" in a for a in devtools_call)


def test_exec_wraps_a_timeout_as_a_stack_error(monkeypatch: pytest.MonkeyPatch) -> None:
    def raises(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired(cmd=argv, timeout=1)

    monkeypatch.setattr(subprocess, "run", raises)
    with pytest.raises(stack.StackError, match="timed out"):
        stack._exec(["wslc", "logs", "designer"], timeout=1)
