#!/usr/bin/env python3
"""Fails unless the three bot jobs of ci.yml run on a push and never on a pull
request, while the checks job still runs on both (riftal-infra#1458).
bot-proofs holds the machine-wide rig lock for up to 110 minutes, so a pull
request that started it would queue behind every rig on the machine.
With --selftest, proves each rule can fail on edited copies. Needs PyYAML.
"""

import pathlib
import sys

import yaml

HERE = pathlib.Path(__file__).resolve().parent
GATE = "github.event_name == 'push'"
BOT_JOBS = ("bot-proofs-scope", "bot-proofs", "bots-stopped-file")


def problems(workflow):
    parsed = yaml.safe_load(workflow)
    jobs = parsed["jobs"]
    errors = []
    # PyYAML reads the bare key on as the boolean True.
    triggers = parsed.get("on", parsed.get(True)) or {}
    if "pull_request" not in triggers:
        errors.append("ci.yml has no pull_request trigger, so the checks job never gates a pull request")
    if "push" not in triggers:
        errors.append("ci.yml has no push trigger, so the bot jobs never run")
    for name in BOT_JOBS:
        if name not in jobs:
            errors.append(f"ci.yml has no job {name}")
        elif GATE not in str(jobs[name].get("if", "")):
            errors.append(f"{name} has no `if` holding {GATE}, so a pull request starts it")
    if "if" in jobs["checks"]:
        errors.append(f"checks has an `if`: {jobs['checks']['if']}, and it must run on a pull request")
    return errors


def selftest(workflow):
    def swap(old, new, text):
        assert old in text, f"edit target missing: {old!r}"
        return text.replace(old, new, 1)
    cases = [("good", workflow, None)]
    scope = "    name: bot proofs scope\n    if: " + GATE + "\n"
    cases.append(("scope-ungated", swap(scope, "    name: bot proofs scope\n", workflow), "bot-proofs-scope has no"))
    proofs = "if: always() && " + GATE + " && needs"
    cases.append(("proofs-ungated", swap(proofs, "if: always() && needs", workflow), "bot-proofs has no"))
    stopped = "if: always() && " + GATE + " && (needs"
    cases.append(("filer-ungated", swap(stopped, "if: always() && (needs", workflow), "bots-stopped-file has no"))
    checks = "    name: lint and validate\n"
    cases.append(("checks-gated", swap(checks, checks + "    if: " + GATE + "\n", workflow), "checks has an `if`"))
    cases.append(("no-pull-request", swap("on:\n  pull_request:\n", "on:\n", workflow), "no pull_request trigger"))
    failures = 0
    for name, flow, want in cases:
        got = "\n".join(problems(flow))
        ok = (not got) if want is None else want in got
        print(f"  ok    {name}" if ok else f"::error::{name}: wanted {want!r}, got: {got or 'no problem'}")
        failures += not ok
    return failures


if __name__ == "__main__":
    flow = (HERE.parent / "workflows/ci.yml").read_text(encoding="utf-8")
    if "--selftest" in sys.argv:
        if selftest(flow):
            sys.exit(1)
        print("bot_jobs_event.py refuses every mutant for its own reason")
    else:
        found = problems(flow)
        print(*[f"::error::{error}" for error in found] or ["the bot jobs run on a push to main only"], sep="\n")
        sys.exit(1 if found else 0)
