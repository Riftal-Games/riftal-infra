#!/usr/bin/env python3
"""Enforce this repo's port rules on one compose file.

Reads the compose model `docker compose config --format json` prints for the
file on stdin, so interpolation, anchors, short and long port syntax and port
ranges arrive already resolved by compose itself. A `${VAR:-127.0.0.1}` bind is
judged by its default, the address the stack takes when nobody widens it.

BEDROCK_TCP_PUBLISH. Bedrock is RakNet over UDP. A publish of 19132 that is not
udp gives a container that looks healthy and that no client can join. Compose
reads a publish with no protocol as tcp, so the mistake is silent.

LOOPBACK_BIND_REQUIRED. Instances run with xbox-auth off, so a publish on any
address wider than 127.0.0.1 lets whoever reaches it claim any identity. A
publish with no address binds every interface.

HOST_NETWORK_MODE. network_mode: host puts every listening port on every
interface and leaves no ports list for the rule above to read.

Usage: docker compose -f FILE config --format json | check_port_policy.py FILE
Exit 0 when clean, 1 when there are findings, 2 when the input is unreadable.
"""

from __future__ import annotations

import json
import sys

BEDROCK_PORTS = {19132}
LOOPBACK_BIND = "127.0.0.1"


class Finding:
    def __init__(self, code, path, where, detail):
        self.code = code
        self.path = path
        self.where = where
        self.detail = detail

    def __str__(self):
        return f"{self.path}: {self.code}: {self.where}: {self.detail}"


def check_publish(findings, path, where, port):
    target = port.get("target")
    proto = str(port.get("protocol") or "tcp").lower()
    host_ip = port.get("host_ip") or ""

    if target in BEDROCK_PORTS and proto != "udp":
        findings.append(
            Finding(
                "BEDROCK_TCP_PUBLISH",
                path,
                where,
                f"port {target} published as {proto}. Bedrock is RakNet over UDP; "
                f"declare it as {target}/udp or no client can join.",
            )
        )

    if host_ip != LOOPBACK_BIND:
        findings.append(
            Finding(
                "LOOPBACK_BIND_REQUIRED",
                path,
                where,
                f"publishes {target}/{proto} on {host_ip or 'every interface'}. "
                f"A publish binds {LOOPBACK_BIND} and nothing wider.",
            )
        )


def check_compose(path, model, findings):
    services = model.get("services") or {}
    for name, service in services.items():
        where = f"services.{name}"

        if service.get("network_mode") == "host":
            findings.append(
                Finding(
                    "HOST_NETWORK_MODE",
                    path,
                    where,
                    "network_mode: host puts every listening port on every "
                    "interface and bypasses the publish rules entirely.",
                )
            )

        for index, port in enumerate(service.get("ports") or []):
            check_publish(findings, path, f"{where}.ports[{index}]", port)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    path = argv[1]
    try:
        model = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"{path}: no compose model on stdin: {exc}\n")
        return 2
    if not isinstance(model, dict):
        sys.stderr.write(f"{path}: the compose model is not a mapping\n")
        return 2

    findings = []
    check_compose(path, model, findings)
    for finding in findings:
        print(f"::error file={finding.path}::{finding}")
    print(f"{len(findings)} finding(s) in {path}")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
