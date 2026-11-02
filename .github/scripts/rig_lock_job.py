#!/usr/bin/env python3
"""Fails unless the bot-proofs job takes the rig lock before its first container
step, releases it last under if: always() after the sweep, waits the 3600 s
rig.js waits, and holds it longer than the job's timeout (riftal-infra#1358).
With --selftest, proves each rule can fail on edited copies. Needs PyYAML.
"""

import pathlib
import re
import sys

import yaml

HERE = pathlib.Path(__file__).resolve().parent
TAKE = "bash .github/scripts/rig-lock.sh take"
RELEASE = "bash .github/scripts/rig-lock.sh release"
CONTAINER = ("docker", "devtools_extract", "ci-docker-label")


def constant(script, name):
    found = re.search(rf"^{name}=(\d+)$", script, re.M)
    return int(found[1]) if found else None


def problems(workflow, script, job="bot-proofs"):
    body = yaml.safe_load(workflow)["jobs"][job]
    steps = body["steps"]
    runs = [str(step.get("run", "")).strip() for step in steps]
    errors = []
    if TAKE not in runs:
        return [f"{job} has no step running: {TAKE}"]
    if RELEASE not in runs:
        return [f"{job} has no step running: {RELEASE}"]
    take, release = runs.index(TAKE), runs.index(RELEASE)
    container = next((n for n, run in enumerate(runs) if any(word in run for word in CONTAINER)), len(runs))
    if take > container:
        errors.append(f"the take step is step {take + 1}, after step {container + 1}, the first that runs a container")
    if release != len(steps) - 1:
        errors.append("the release step is not the last step")
    if steps[release].get("if") != "always()":
        errors.append("the release step does not run under if: always(), so a failed step leaves the lock to expire")
    if not any("ci-container-sweep.sh" in run for run in runs[:release]):
        errors.append("the release step does not come after the container sweep")
    if constant(script, "RIG_LOCK_WAIT_SEC") != 3600:
        errors.append("RIG_LOCK_WAIT_SEC is not 3600, the wait rig.js uses")
    if (hold := constant(script, "RIG_LOCK_HOLD_SEC")) is None or hold < int(body["timeout-minutes"]) * 60:
        errors.append(f"RIG_LOCK_HOLD_SEC {hold} is under the {job} timeout of {body['timeout-minutes']} minutes, so the lock can expire while the job runs")
    return errors


def selftest(workflow, script):
    def swap(old, new, text):
        assert old in text, f"edit target missing: {old!r}"
        return text.replace(old, new, 1)
    take_step = f"      - name: Take the machine-wide rig lock\n        run: {TAKE}\n\n"
    label = "rig-lock.sh rig-up-check\n\n      - name: Label this job's containers\n        run: bash .github/scripts/ci-docker-label.sh\n\n"
    sweep_note = "      # Every step from here may start a bot."
    release_if = f"        if: always()\n        run: {RELEASE}\n"
    moved, failures = swap(take_step, "", workflow), 0
    cases = [
        ("good", workflow, script, None),
        ("release-without-always", swap(release_if, f"        run: {RELEASE}\n", workflow), script, "if: always()"),
        ("take-after-label", swap(label, label + take_step, moved), script, "first that runs a container"),
        ("take-after-extract", swap(sweep_note, take_step + sweep_note, moved), script, "first that runs a container"),
        ("wait-shortened", workflow, swap("RIG_LOCK_WAIT_SEC=3600", "RIG_LOCK_WAIT_SEC=2700", script), "RIG_LOCK_WAIT_SEC"),
        ("hold-under-timeout", workflow, swap("RIG_LOCK_HOLD_SEC=6000", "RIG_LOCK_HOLD_SEC=1200", script), "RIG_LOCK_HOLD_SEC"),
        ("timeout-over-hold", swap("timeout-minutes: 90", "timeout-minutes: 105", workflow), script, "RIG_LOCK_HOLD_SEC"),
    ]
    for name, flow, text, want in cases:
        got = "\n".join(problems(flow, text))
        ok = (not got) if want is None else want in got
        print(f"  ok    {name}" if ok else f"::error::{name}: wanted {want!r}, got: {got or 'no problem'}")
        failures += not ok
    return failures


if __name__ == "__main__":
    flow = (HERE.parent / "workflows/ci.yml").read_text(encoding="utf-8")
    text = (HERE / "rig-lock.sh").read_text(encoding="utf-8")
    if "--selftest" in sys.argv:
        if selftest(flow, text):
            sys.exit(1)
        print("rig_lock_job.py refuses every mutant for its own reason")
    else:
        found = problems(flow, text)
        print(*[f"::error::{error}" for error in found] or ["bot-proofs takes the rig lock first and releases it last"], sep="\n")
        sys.exit(1 if found else 0)
