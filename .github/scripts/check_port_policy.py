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

With --alpha, for a compose file under deploy/alpha/, one service authenticates
its own players, so LOOPBACK_BIND_REQUIRED's reason does not hold for it and the
policy states the invariant that does. A publishing service is refused unless
its POCKETMINE_ARGS, as the model resolves it from env_file, carries each of
--xbox-auth=true (ALPHA_PUBLISH_XBOX_AUTH), --auto-report.enabled=0
(ALPHA_PUBLISH_CRASH_UPLOAD), --enable-ipv6=0 (ALPHA_PUBLISH_IPV6) and
--transport.name=raknet (ALPHA_PUBLISH_TRANSPORT) exactly once and no other
value of it. Core reads a repeated option as an array, which getPropertyBool
casts to true and getConfigBool reads as false, so a flag given twice is
refused even when both tokens agree. The crash upload flag is 0 because core
casts the string false to true. ALPHA_PUBLISH_VERIFY_XUID is any
--player.verify-xuid token, which stays at core's default.
ALPHA_PUBLISH_DEV_BOTS is --riftal-dev-bots in that value or in its command,
and ALPHA_PUBLISH_DEV_ENV is RIFTAL_DEV_ENV anywhere in its environment.
ALPHA_PUBLISH_PORT is a publish of anything but 19132:19132/udp.
ALPHA_MULTIPLE_PUBLISHERS is a file with more than one publishing service. The
loopback default holds there too.

Usage: docker compose -f FILE config --format json |
         check_port_policy.py [--alpha] FILE
Exit 0 when clean, 1 when there are findings, 2 when the input is unreadable.
"""

from __future__ import annotations

import json
import sys

BEDROCK_PORTS = {19132}
LOOPBACK_BIND = "127.0.0.1"
ALPHA_REQUIRED_FLAGS = (
    ("ALPHA_PUBLISH_XBOX_AUTH", "--xbox-auth", "true"),
    ("ALPHA_PUBLISH_CRASH_UPLOAD", "--auto-report.enabled", "0"),
    ("ALPHA_PUBLISH_IPV6", "--enable-ipv6", "0"),
    ("ALPHA_PUBLISH_TRANSPORT", "--transport.name", "raknet"),
)
ALPHA_VERIFY_XUID_FLAG = "--player.verify-xuid"
ALPHA_PUBLISHED = "19132"
ALPHA_TARGET = 19132
ALPHA_DEV_BOTS_FLAG = "--riftal-dev-bots"
ALPHA_DEV_ENV = "RIFTAL_DEV_ENV"


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


def is_alpha_publish(port):
    # 19132:19132 on a protocol other than udp is BEDROCK_TCP_PUBLISH's to
    # report, so it is not reported twice.
    return (
        str(port.get("published") or "") == ALPHA_PUBLISHED
        and port.get("target") == ALPHA_TARGET
    )


def option_tokens(tokens, name):
    return [t for t in tokens if t == name or t.startswith(name + "=")]


def command_text(service):
    command = service.get("command") or ""
    if isinstance(command, list):
        return " ".join(str(part) for part in command)
    return str(command)


def check_alpha_publisher(findings, path, where, service):
    environment = service.get("environment") or {}
    args = environment.get("POCKETMINE_ARGS") or ""
    tokens = args.split()

    for code, name, value in ALPHA_REQUIRED_FLAGS:
        given = option_tokens(tokens, name)
        if given != [f"{name}={value}"]:
            findings.append(
                Finding(
                    code,
                    path,
                    where,
                    f"publishes a port but its POCKETMINE_ARGS "
                    f"({args or 'unset'}) does not carry {name}={value} "
                    f"exactly once and no other value of {name}.",
                )
            )

    if option_tokens(tokens, ALPHA_VERIFY_XUID_FLAG):
        findings.append(
            Finding(
                "ALPHA_PUBLISH_VERIFY_XUID",
                path,
                where,
                f"publishes a port and names {ALPHA_VERIFY_XUID_FLAG} in its "
                "POCKETMINE_ARGS. It stays at core's default.",
            )
        )

    refused = [
        f"{port.get('published') or 'unset'}:{port.get('target')}/"
        f"{str(port.get('protocol') or 'tcp').lower()}"
        for port in service.get("ports") or []
        if not is_alpha_publish(port)
    ]
    if refused:
        findings.append(
            Finding(
                "ALPHA_PUBLISH_PORT",
                path,
                where,
                f"publishes {', '.join(refused)}. The one publish is "
                "19132:19132/udp.",
            )
        )

    if ALPHA_DEV_BOTS_FLAG in args or ALPHA_DEV_BOTS_FLAG in command_text(service):
        findings.append(
            Finding(
                "ALPHA_PUBLISH_DEV_BOTS",
                path,
                where,
                f"publishes a port and names {ALPHA_DEV_BOTS_FLAG} in its "
                "POCKETMINE_ARGS or command.",
            )
        )

    if ALPHA_DEV_ENV in environment:
        findings.append(
            Finding(
                "ALPHA_PUBLISH_DEV_ENV",
                path,
                where,
                f"publishes a port and sets {ALPHA_DEV_ENV} in its environment.",
            )
        )


def check_compose(path, model, findings, alpha=False):
    services = model.get("services") or {}
    publishers = [name for name, s in services.items() if s.get("ports")]
    if alpha and len(publishers) > 1:
        findings.append(
            Finding(
                "ALPHA_MULTIPLE_PUBLISHERS",
                path,
                "services",
                f"{len(publishers)} services publish a port "
                f"({', '.join(publishers)}). Only the one instance may.",
            )
        )

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

        if alpha and service.get("ports"):
            check_alpha_publisher(findings, path, where, service)


def main(argv):
    args = argv[1:]
    alpha = "--alpha" in args
    args = [a for a in args if a != "--alpha"]
    if len(args) != 1:
        sys.stderr.write(__doc__)
        return 2
    path = args[0]
    try:
        model = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"{path}: no compose model on stdin: {exc}\n")
        return 2
    if not isinstance(model, dict):
        sys.stderr.write(f"{path}: the compose model is not a mapping\n")
        return 2

    findings = []
    check_compose(path, model, findings, alpha)
    for finding in findings:
        print(f"::error file={finding.path}::{finding}")
    print(f"{len(findings)} finding(s) in {path}")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
