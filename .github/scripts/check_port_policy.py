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

Exit 0 when clean, 1 when there are findings, 2 on a usage error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
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

# -p / --publish in a shell script or runbook command.
PUBLISH_FLAG = re.compile(
    r"(?:^|\s)(?:-p|--publish)(?:[=\s]+)([\"']?)([^\s\"';|&]+)\1"
)
PUBLISH_ALL_FLAG = re.compile(r"(?:^|\s)(?:-P|--publish-all)(?:\s|$)")
PROXY_HINT = re.compile(r"proxy|waterdog", re.IGNORECASE)


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


def check_script(path, findings):
    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()
    # Fold backslash continuations so a multi-line docker run reads as one command.
    folded = raw.replace("\\\n", " ")
    for lineno, line in enumerate(folded.splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        where = f"line {lineno}"
        if PUBLISH_ALL_FLAG.search(line):
            findings.append(
                Finding(
                    "PUBLISH_ALL_NOT_ALLOWED",
                    path,
                    where,
                    "-P / --publish-all publishes every exposed port to the host.",
                )
            )
        for match in PUBLISH_FLAG.finditer(line):
            host_ip, published, target, proto = parse_mapping(match.group(2))
            # A run command names its own role: the proxy is the only thing in
            # this repo allowed to publish publicly, so require it to say so.
            if PROXY_HINT.search(line):
                tier = "public"
            elif (host_ip or "") in LOOPBACK_IPS:
                tier = "loopback"
            else:
                tier = None
            check_publish(
                findings, path, where, host_ip, published, target, proto, tier
            )


def is_compose(name):
    return bool(COMPOSE_NAME.match(name) or COMPOSE_SUFFIX.search(name))


def collect(roots, excludes):
    compose, scripts = [], []
    for root in roots:
        if os.path.isfile(root):
            name = os.path.basename(root)
            if is_compose(name):
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
                if is_compose(filename):
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
    args = parser.parse_args(argv)

    roots = args.paths or ["."]
    compose_files, scripts = collect(roots, args.exclude)

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
