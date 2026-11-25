#!/usr/bin/env python3
"""Fails unless the bot-proofs job takes the rig lock before its first container
step, releases it last under if: always() after the sweep, waits the 4680 s
rig.js waits, leaves the job's timeout room for that wait and the harness, and
holds it longer than the job's timeout (riftal-infra#1358).
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
# What the job's other steps take besides the lock wait and the harness: 120 s of
# steps before the take, then the devtools extract, the mysql pull, the merge-base
# fetch, the container sweep and the release in 180 s.
STEPS_SEC = 300


def constant(script, name):
    found = re.search(rf"(?:^|\s){name}=(\d+)(?:\s|$)", script, re.M)
    return int(found[1]) if found else None


def problems(workflow, script, harness, job="bot-proofs"):
    deadline, grace = constant(harness, "DEADLINE"), constant(harness, "KILL_GRACE")
    if deadline is None or grace is None:
        return ["deploy/bot-proofs.sh sets no DEADLINE and KILL_GRACE"]
    body_sec = deadline + grace + STEPS_SEC
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
    wait = constant(script, "RIG_LOCK_WAIT_SEC")
    if wait != 4680:
        errors.append("RIG_LOCK_WAIT_SEC is not 4680, the wait rig.js uses")
    elif int(body["timeout-minutes"]) * 60 < wait + body_sec:
        errors.append(f"the {job} timeout of {body['timeout-minutes']} minutes is under RIG_LOCK_WAIT_SEC {wait} plus the {body_sec} s body, so a job that waits the full wait cannot finish")
    if (hold := constant(script, "RIG_LOCK_HOLD_SEC")) is None or hold < int(body["timeout-minutes"]) * 60:
        errors.append(f"RIG_LOCK_HOLD_SEC {hold} is under the {job} timeout of {body['timeout-minutes']} minutes, so the lock can expire while the job runs")
    return errors


def selftest(workflow, script, harness):
    def swap(old, new, text):
        assert old in text, f"edit target missing: {old!r}"
        return text.replace(old, new, 1)
    take_step = f"      - name: Take the machine-wide rig lock\n        run: {TAKE}\n\n"
    label = "rig-lock.sh rig-up-check\n\n      - name: Label this job's containers\n        run: bash .github/scripts/ci-docker-label.sh\n\n"
    sweep_note = "      # Every step from here may start a bot."
    release_if = f"        if: always()\n        run: {RELEASE}\n"
    moved, failures = swap(take_step, "", workflow), 0
    cases = [
        ("good", workflow, script, harness, None),
        ("release-without-always", swap(release_if, f"        run: {RELEASE}\n", workflow), script, harness, "if: always()"),
        ("take-after-label", swap(label, label + take_step, moved), script, harness, "first that runs a container"),
        ("take-after-extract", swap(sweep_note, take_step + sweep_note, moved), script, harness, "first that runs a container"),
        ("wait-shortened", workflow, swap("RIG_LOCK_WAIT_SEC=4680", "RIG_LOCK_WAIT_SEC=2700", script), harness, "RIG_LOCK_WAIT_SEC"),
        ("timeout-under-wait-and-body", swap("timeout-minutes: 119", "timeout-minutes: 100", workflow), script, harness, "plus the 2460 s body"),
        ("deadline-past-timeout", workflow, script, swap("DEADLINE=2040", "DEADLINE=2100", harness), "plus the 2520 s body"),
        ("deadline-missing", workflow, script, swap("DEADLINE=2040", "DEADLINE_SEC=2040", harness), "sets no DEADLINE"),
        ("hold-under-timeout", workflow, swap("RIG_LOCK_HOLD_SEC=7200", "RIG_LOCK_HOLD_SEC=1200", script), harness, "RIG_LOCK_HOLD_SEC"),
        ("timeout-over-hold", swap("timeout-minutes: 119", "timeout-minutes: 125", workflow), script, harness, "RIG_LOCK_HOLD_SEC"),
    ]
    for name, flow, text, plan, want in cases:
        got = "\n".join(problems(flow, text, plan))
        ok = (not got) if want is None else want in got
        print(f"  ok    {name}" if ok else f"::error::{name}: wanted {want!r}, got: {got or 'no problem'}")
        failures += not ok
    return failures


if __name__ == "__main__":
    flow = (HERE.parent / "workflows/ci.yml").read_text(encoding="utf-8")
    text = (HERE / "rig-lock.sh").read_text(encoding="utf-8")
    plan = (HERE.parent.parent / "deploy/bot-proofs.sh").read_text(encoding="utf-8")
    if "--selftest" in sys.argv:
        if selftest(flow, text, plan):
            sys.exit(1)
        print("rig_lock_job.py refuses every mutant for its own reason")
    else:
        found = problems(flow, text, plan)
        print(*[f"::error::{error}" for error in found] or ["bot-proofs takes the rig lock first and releases it last"], sep="\n")
        sys.exit(1 if found else 0)
