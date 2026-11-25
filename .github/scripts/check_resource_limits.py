#!/usr/bin/env python3
"""Enforce a memory and a CPU limit on every long-running service of one compose file.

Reads the compose model `docker compose config --format json` prints for the
file on stdin, so interpolation and anchors arrive already resolved. An
unbounded stack exhausted the dev PC's memory and froze it, and `docker compose
config --quiet` accepts a file whose limit lines were deleted.

MEMORY_LIMIT_MISSING. mem_limit is absent, zero or not a number.

CPU_LIMIT_MISSING. cpus is absent, zero or not a number.

A one-shot service is exempt: one that another service waits on with
`condition: service_completed_successfully`. It exits and holds no memory
afterwards. Every other service, including one behind a profile, runs until it
is stopped and needs both limits.

Usage: docker compose --profile '*' -f FILE config --format json | check_resource_limits.py FILE
Exit 0 when clean, 1 when there are findings, 2 when the input is unreadable.
"""

from __future__ import annotations

import json
import sys


def positive(value):
    try:
        return float(value) > 0
    except (TypeError, ValueError):
        return False


def one_shot_services(services):
    names = set()
    for service in services.values():
        depends_on = service.get("depends_on") or {}
        if not isinstance(depends_on, dict):
            continue
        for name, dependency in depends_on.items():
            if (dependency or {}).get("condition") == "service_completed_successfully":
                names.add(name)
    return names


def check_compose(path, model, findings):
    services = model.get("services") or {}
    exempt = one_shot_services(services)
    for name, service in services.items():
        if name in exempt:
            continue
        if not positive(service.get("mem_limit")):
            findings.append((path, "MEMORY_LIMIT_MISSING", f"services.{name}"))
        if not positive(service.get("cpus")):
            findings.append((path, "CPU_LIMIT_MISSING", f"services.{name}"))


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
    for file, code, where in findings:
        print(f"::error file={file}::{file}: {code}: {where}: set a nonzero limit")
    print(f"{len(findings)} finding(s) in {path}")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
