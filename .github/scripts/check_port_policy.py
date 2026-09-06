#!/usr/bin/env python3
"""Enforce this repo's two port rules on every compose file and run script.

Rule 1, UDP. Bedrock is RakNet over UDP. A publish of 19132 that is not
declared /udp produces a container that looks perfectly healthy and that no
client can join. Compose and docker both default to tcp when the protocol is
left off, so the mistake is silent and the symptom looks like a protocol bug.

Rule 2, default deny on host publishing. Downstream instances run in offline
mode, xbox-auth=false and player.verify-xuid: false, so a host-published
instance port is an open door. Instance ports belong on the proxy container
network only. The allowlist below is therefore closed: a service nobody has
named is denied, because a security check that only catches the names someone
thought of catches nothing on the day it matters.

Both paths decide the same way. A compose service is classified by its service
name, a run command by its --name, or by its image when it has no --name.
Nothing else on the line grants permission: instance ports live on the proxy's
container network by house convention, so a downstream run command names a
proxy network right next to its -p, and anything that read the whole line
would hand that downstream the proxy's permission.

Discovery is by content, not by filename. Any *.yml or *.yaml that parses to a
mapping with a top-level services key is compose, because a file called
stack.yaml is the one that gets missed, and being missed is silent.

Exit 0 when clean, 1 when there are findings, 2 on a usage error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("PyYAML is required: python3 -m pip install pyyaml\n")
    raise SystemExit(2)

# The Bedrock listen port. Anything published on it has to be udp.
BEDROCK_PORTS = {19132}

# Services permitted to publish to a host interface at all. Everything else is
# denied. Adding a name here is a deliberate, reviewable act.
#   "public"   may bind any interface. Only the proxy, the sole public entry point.
#   "loopback" may bind 127.0.0.1 or ::1 and nothing else.
PUBLISH_ALLOWLIST = {
    "proxy": "public",
    "waterdog": "public",
    "waterdogpe": "public",
    "mysql": "loopback",
    "mariadb": "loopback",
    "db": "loopback",
    "database": "loopback",
}

LOOPBACK_IPS = {"127.0.0.1", "::1", "[::1]", "localhost"}

COMPOSE_NAME = re.compile(r"^(docker-)?compose([.-][\w-]+)?\.ya?ml$", re.IGNORECASE)
COMPOSE_SUFFIX = re.compile(r"\.compose\.ya?ml$", re.IGNORECASE)
YAML_NAME = re.compile(r"\.ya?ml$", re.IGNORECASE)
SERVICES_KEY = re.compile(r"^services\s*:", re.MULTILINE)

# Only these command lines are container publishes. `mkdir -p /opt/riftal/state`
# is not one, and a gate that reddens on ordinary shell gets weakened by the
# first person who hits it, which kills the control by attrition.
CONTAINER_BINARIES = {"docker", "podman", "nerdctl", "wslc"}
RUN_SUBCOMMANDS = {"run", "create"}
# Where a run command stops and the next shell command starts.
SHELL_BREAKS = {";", "&&", "||", "|", "&", "(", ")", "{", "}", ">", ">>", "<"}

PUBLISH_FLAGS = {"-p", "--publish"}
PUBLISH_ALL_FLAGS = {"-P", "--publish-all"}
NAME_FLAGS = {"--name"}

# Short flags that consume a value, so `-p19132:19132` and `-p 19132:19132`
# are the same publish. Docker accepts the attached form and a match that
# required a separator never saw it.
SHORT_VALUE_FLAGS = set("pveuwlhm")

# Long flags that consume the following token, and long flags that take no
# value. Both are listed, because a flag in neither table is one this parser
# does not know, and an unknown flag is handled by failing closed rather than
# by guessing: see parse_run. Guessing boolean was a silent false negative,
# because the flag's value was then read as the image and the rest of the
# command, including any -p, was never scanned. Ordinary shell such as
# `mkdir -p` is kept out by the container-binary gate in container_runs, not by
# these tables, so failing closed here costs nothing outside a run command.
LONG_VALUE_FLAGS = {
    "--add-host", "--annotation", "--attach", "--blkio-weight", "--cap-add",
    "--cap-drop", "--cgroup-parent", "--cgroupns", "--cidfile", "--cpus",
    "--cpuset-cpus", "--detach-keys", "--device", "--device-read-bps",
    "--device-write-bps", "--dns", "--dns-option", "--dns-search",
    "--entrypoint", "--env", "--env-file", "--expose", "--gpus", "--group-add",
    "--health-cmd", "--health-interval", "--health-retries",
    "--health-start-period", "--health-timeout", "--hostname", "--ip", "--ip6",
    "--ipc", "--isolation", "--label", "--link", "--log-driver", "--log-opt",
    "--mac-address", "--memory", "--memory-swap", "--mount", "--name", "--net",
    "--network", "--network-alias", "--oom-score-adj", "--pid", "--pids-limit",
    "--platform", "--pod", "--publish", "--pull", "--restart", "--runtime",
    "--secret", "--security-opt", "--shm-size", "--stop-signal",
    "--stop-timeout", "--storage-opt", "--sysctl", "--tmpfs", "--ulimit",
    "--user", "--userns", "--uts", "--volume", "--volumes-from", "--workdir",
}

LONG_BOOLEAN_FLAGS = {
    "--detach", "--disable-content-trust", "--help", "--http-proxy", "--init",
    "--interactive", "--no-healthcheck", "--no-hostname", "--no-hosts",
    "--oom-kill-disable", "--passwd", "--privileged", "--publish-all",
    "--quiet", "--read-only", "--replace", "--rm", "--rmi", "--rootfs",
    "--sig-proxy", "--tty", "--unsetenv-all",
}


def unknown_long_flag(token):
    """True for a long flag this parser has no arity for.

    `--memory-reservation=1g` is self-describing and needs no table; a bare
    `--memory-reservation` does not, and neither table names it.
    """
    if not token.startswith("--") or "=" in token:
        return False
    return token not in LONG_VALUE_FLAGS and token not in LONG_BOOLEAN_FLAGS


class Finding:
    def __init__(self, code, path, where, detail):
        self.code = code
        self.path = path
        self.where = where
        self.detail = detail

    def as_dict(self):
        return {
            "code": self.code,
            "path": self.path,
            "where": self.where,
            "detail": self.detail,
        }

    def __str__(self):
        return f"{self.path}: {self.code}: {self.where}: {self.detail}"


def parse_mapping(spec):
    """Split a short-syntax port spec into (host_ip, published, target, proto)."""
    spec = str(spec).strip()
    proto = "tcp"
    body = spec
    if "/" in spec:
        body, _, proto = spec.rpartition("/")
        proto = proto.lower()
    parts = body.rsplit(":", 2)
    if len(parts) == 3:
        host_ip, published, target = parts
    elif len(parts) == 2:
        host_ip, published, target = None, parts[0], parts[1]
    else:
        # Bare container port: docker still publishes it, on a random host port.
        host_ip, published, target = None, None, parts[0]
    return host_ip, published, target, proto


def target_ports(target):
    """Expand a target that may be a range into the ports it covers."""
    out = set()
    if target is None:
        return out
    target = str(target)
    if "-" in target:
        lo, _, hi = target.partition("-")
        try:
            lo_i, hi_i = int(lo), int(hi)
        except ValueError:
            return out
        if hi_i - lo_i > 10000:
            return out
        return set(range(lo_i, hi_i + 1))
    try:
        out.add(int(target))
    except ValueError:
        pass
    return out


def classify(service_name):
    """Return the allowlist tier for a service name, or None if denied."""
    name = (service_name or "").lower()
    if name in PUBLISH_ALLOWLIST:
        return PUBLISH_ALLOWLIST[name]
    # Suffixed or prefixed variants, e.g. riftal-proxy, proxy-1.
    for key, tier in PUBLISH_ALLOWLIST.items():
        if re.fullmatch(rf"[\w.-]*(^|[-_.]){re.escape(key)}([-_.][\w.-]*)?", name):
            return tier
    return None


def check_publish(findings, path, where, host_ip, published, target, proto, tier):
    ports = target_ports(target)

    if ports & BEDROCK_PORTS and proto != "udp":
        findings.append(
            Finding(
                "BEDROCK_TCP_PUBLISH",
                path,
                where,
                f"port {target} published as {proto}. Bedrock is RakNet over UDP; "
                f"declare it as {target}/udp or no client can join.",
            )
        )

    if tier is None:
        findings.append(
            Finding(
                "HOST_PUBLISH_NOT_ALLOWED",
                path,
                where,
                f"publishes {published or 'an ephemeral host port'} -> {target}/{proto} "
                "to a host interface. Downstream instances run in offline mode and must "
                "reach the host through the proxy container network only. If this really "
                "is a public entry point, add it to PUBLISH_ALLOWLIST in "
                ".github/scripts/check_port_policy.py so the exception is reviewed.",
            )
        )
    elif tier == "loopback" and (host_ip or "") not in LOOPBACK_IPS:
        findings.append(
            Finding(
                "LOOPBACK_BIND_REQUIRED",
                path,
                where,
                f"publishes {target}/{proto} on "
                f"{host_ip or 'every host interface'}. This service may only bind "
                "127.0.0.1.",
            )
        )


def check_compose(path, findings):
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        findings.append(
            Finding("COMPOSE_UNPARSEABLE", path, "<file>", str(exc).replace("\n", " "))
        )
        return
    if not isinstance(doc, dict):
        findings.append(
            Finding("COMPOSE_UNPARSEABLE", path, "<file>", "top level is not a mapping")
        )
        return

    services = doc.get("services") or {}
    if not isinstance(services, dict):
        findings.append(
            Finding("COMPOSE_UNPARSEABLE", path, "services", "services is not a mapping")
        )
        return

    for name, service in services.items():
        if not isinstance(service, dict):
            continue
        tier = classify(name)
        where = f"services.{name}"

        if service.get("network_mode") == "host":
            findings.append(
                Finding(
                    "HOST_NETWORK_MODE",
                    path,
                    where,
                    "network_mode: host puts every listening port straight onto the "
                    "host and bypasses publish rules entirely.",
                )
            )

        ports = service.get("ports") or []
        if not isinstance(ports, list):
            findings.append(
                Finding(
                    "COMPOSE_SCHEMA",
                    path,
                    f"{where}.ports",
                    "ports must be a sequence; compose will refuse this file.",
                )
            )
            continue

        for entry in ports:
            if isinstance(entry, dict):
                host_ip = entry.get("host_ip")
                published = entry.get("published")
                target = entry.get("target")
                proto = str(entry.get("protocol") or "tcp").lower()
            else:
                host_ip, published, target, proto = parse_mapping(entry)
            check_publish(
                findings, path, where, host_ip, published, target, proto, tier
            )


def shell_tokens(line):
    """Split a shell line into words, tolerating anything shlex chokes on."""
    try:
        return shlex.split(line, comments=True)
    except ValueError:
        return line.split()


def flag_events(tokens, index):
    """Expand one flag token into (flag, value) pairs. Returns (events, index).

    Handles `--publish 19132:19132`, `--publish=19132:19132`, `-p 19132:19132`,
    the attached `-p19132:19132`, and short clusters such as `-dP`.
    """
    token = tokens[index]
    if token.startswith("--"):
        flag, sep, attached = token.partition("=")
        if sep:
            return [(flag, attached)], index
        if flag in LONG_VALUE_FLAGS and index + 1 < len(tokens):
            return [(flag, tokens[index + 1])], index + 1
        return [(flag, None)], index

    events = []
    body = token[1:]
    for position, char in enumerate(body):
        if char in SHORT_VALUE_FLAGS:
            rest = body[position + 1 :]
            if rest:
                events.append(("-" + char, rest))
            elif index + 1 < len(tokens):
                index += 1
                events.append(("-" + char, tokens[index]))
            else:
                events.append(("-" + char, None))
            return events, index
        events.append(("-" + char, None))
    return events, index


def parse_run(tokens, index):
    """Read one container run command. Returns (publishes, publish_all, name,
    image, index-after-the-command)."""
    publishes, publish_all, name, image = [], False, None, None
    # Fail closed on a flag we cannot size. If an unknown long flag consumes a
    # value, that value looks exactly like the image, so the image boundary is
    # no longer trustworthy and we keep reading publish flags to the end of the
    # command instead of stopping at it.
    image_boundary_known = True
    while index < len(tokens):
        token = tokens[index]
        if token in SHELL_BREAKS:
            break
        if token.startswith("-") and token != "-":
            if unknown_long_flag(token):
                image_boundary_known = False
            events, index = flag_events(tokens, index)
            for flag, value in events:
                if flag in PUBLISH_FLAGS and value:
                    publishes.append(value)
                elif flag in PUBLISH_ALL_FLAGS:
                    publish_all = True
                elif flag in NAME_FLAGS and value:
                    name = value
            index += 1
            continue
        # The first bare word is the image. Everything after it is the
        # container's own command, which docker does not interpret, so neither
        # do we: `docker run img sh -c "mkdir -p /data"` is not a publish.
        # That holds only while every flag ahead of it was one we can size; if
        # one was not, this word may be that flag's value, so we go on looking
        # for a publish to the end of the command. A misread image name lands
        # on the deny side, because classify() grants nothing it cannot match.
        if image is None:
            image = token
        index += 1
        if image_boundary_known:
            break
    return publishes, publish_all, name, image, index


def image_role(image):
    """The role an image name claims: ghcr.io/riftal-games/waterdogpe:tag ->
    waterdogpe."""
    ref = image.split("@", 1)[0]
    last = ref.rsplit("/", 1)[-1]
    return last.split(":", 1)[0]


def run_tier(name, image):
    """Classify a run command exactly as the compose path classifies a service:
    by the name it goes by. Nothing else on the line is evidence of a role."""
    if name:
        return classify(name), f"--name {name}"
    if image:
        return classify(image_role(image)), f"image {image}"
    return None, "unnamed container"


def container_runs(tokens):
    """Yield each container run/create command found in a line of shell."""
    runs = []
    index = 0
    while index < len(tokens):
        base = os.path.basename(tokens[index]).lower()
        if base in CONTAINER_BINARIES:
            cursor = index + 1
            while cursor < len(tokens) and tokens[cursor].startswith("-"):
                cursor += 1
            if cursor < len(tokens) and tokens[cursor].lower() == "container":
                cursor += 1
                while cursor < len(tokens) and tokens[cursor].startswith("-"):
                    cursor += 1
            if cursor < len(tokens) and tokens[cursor].lower() in RUN_SUBCOMMANDS:
                publishes, publish_all, name, image, index = parse_run(
                    tokens, cursor + 1
                )
                runs.append((publishes, publish_all, name, image))
                continue
        index += 1
    return runs


def check_script(path, findings):
    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()
    # Fold backslash continuations so a multi-line docker run reads as one command.
    folded = raw.replace("\\\n", " ")
    for lineno, line in enumerate(folded.splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        for publishes, publish_all, name, image in container_runs(shell_tokens(line)):
            tier, role = run_tier(name, image)
            where = f"line {lineno} ({role})"
            if publish_all:
                findings.append(
                    Finding(
                        "PUBLISH_ALL_NOT_ALLOWED",
                        path,
                        where,
                        "-P / --publish-all publishes every exposed port to the host.",
                    )
                )
            for spec in publishes:
                host_ip, published, target, proto = parse_mapping(spec)
                check_publish(
                    findings, path, where, host_ip, published, target, proto, tier
                )


def has_services_key(path):
    """True when a YAML file is a compose file, decided by what is in it."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return False
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError:
        # Unparseable YAML cannot be probed, so fall back to the literal key. A
        # file that claims to be compose and does not parse is a finding to
        # report, not a file to walk past.
        return bool(SERVICES_KEY.search(text))
    return isinstance(doc, dict) and "services" in doc


def is_compose(path, name=None):
    name = name if name is not None else os.path.basename(path)
    if COMPOSE_NAME.match(name) or COMPOSE_SUFFIX.search(name):
        return True
    if not YAML_NAME.search(name):
        return False
    return has_services_key(path)


def collect(roots, excludes):
    compose, scripts = [], []
    for root in roots:
        if os.path.isfile(root):
            name = os.path.basename(root)
            if is_compose(root, name):
                compose.append(root)
            elif name.endswith(".sh"):
                scripts.append(root)
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [
                d
                for d in dirnames
                if d not in {".git"}
                and not any(
                    os.path.normpath(os.path.join(dirpath, d)).replace("\\", "/")
                    .endswith(ex.rstrip("/"))
                    for ex in excludes
                )
            ]
            for filename in filenames:
                full = os.path.join(dirpath, filename)
                if is_compose(full, filename):
                    compose.append(full)
                elif filename.endswith(".sh"):
                    scripts.append(full)
    return sorted(compose), sorted(scripts)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", default=["."])
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="directory path suffix to skip, repeatable",
    )
    parser.add_argument("--json", action="store_true", help="machine readable output")
    parser.add_argument(
        "--list",
        choices=["compose", "scripts"],
        help="print the discovered files and exit, so a caller never has to "
        "re-implement discovery and drift away from it",
    )
    args = parser.parse_args(argv)

    roots = args.paths or ["."]
    compose_files, scripts = collect(roots, args.exclude)

    if args.list:
        for path in compose_files if args.list == "compose" else scripts:
            print(path)
        return 0

    findings = []
    for path in compose_files:
        check_compose(path, findings)
    for path in scripts:
        check_script(path, findings)

    if args.json:
        print(json.dumps([f.as_dict() for f in findings], indent=2))
    else:
        print(
            f"scanned {len(compose_files)} compose file(s) and "
            f"{len(scripts)} shell script(s) under {', '.join(roots)}"
        )
        for path in compose_files + scripts:
            print(f"  checked {path}")
        for finding in findings:
            print(f"::error file={finding.path}::{finding}")
        print(f"{len(findings)} finding(s)")

    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
