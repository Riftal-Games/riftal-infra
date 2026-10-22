#!/usr/bin/env python3
"""Fails unless the bot-proofs job writes exposure=pending in a step of its own
before any step that is not on the allowlist (ADR 024 item 3). A cancelled run
carries the job output of the steps that completed, so a bot started first
leaves bots-stopped-file nothing to file.

Every value compared is read after YAML parsing, from the text of PyYAML's
composed scalar nodes and never their resolved type, so quoting, comments,
spacing, flow style and folded, block or continued scalars arrive as the string
the parser reads.

Refused for the whole file, which ends the check: a character outside printable
ASCII other than carriage return and newline, tested on the raw text before
parsing; an anchor, an alias or a tag, tested on PyYAML's event stream while it
parses; text PyYAML cannot read as exactly one document. Refused at each mapping
or scalar the check reads, which also ends the check: a key or a value holding a
character outside printable ASCII and newline, as a double-quoted escape can; a
key repeated in a mapping; a key that is not a scalar; a node of the wrong kind.
The mappings read are the workflow, its env, its jobs, the job, its outputs,
every step, and the env and with of a step ahead of the pending step. Every key
and value the check reads is therefore printable ASCII and newline, where
Python's lower() and .NET's ordinal ignore-case comparison agree, which is why
the lowercase comparisons of job ids, outputs keys and step ids below are sound.
A file that cannot be opened fails the check with an error. A file that is not
valid UTF-8 stops the script with a traceback and exit status 1.

Keys allowed, any other refused:
  workflow  name, on, permissions, concurrency, env (HADOLINT_VERSION and
            HADOLINT_SHA256 only), jobs.
  job       name, needs, if, runs-on, timeout-minutes, permissions, outputs,
            steps.
  step      for a step ahead of the pending step, and for every step when
            there is none: name, id, uses, if, continue-on-error, run, env
            (GITHUB_TOKEN set to ${{ github.token }} only), with.
A step ahead of the pending step is actions/checkout by a 40-hex sha, with
persist-credentials: false as its only with entry and no env, or a run whose
every line, once spaces around it are dropped and blank and # lines are set
apart, is in RUN_LINES. The pending step has an id, a run that is PENDING_WRITE
once spaces and newlines around it are dropped and no key but name, id, run and
continue-on-error, which is accepted only as a plain false. A step not after
the pending step whose run contains exposure=pending is refused unless it is the
pending step. Ids start with a letter or _ and go on in letters, digits, _ and -.

GitHub looks steps.<id> up without regard to case (actions/runner b6d10b5,
src/Sdk/DTPipelines/Pipelines/ContextData/DictionaryContextData.cs:77, behind
src/Runner.Worker/StepsContext.cs), so ids compare lowercased and two that
differ only by case are refused. Also refused: a job that is not in the
workflow, another job id that differs from the job's only by case, and steps
that is not a sequence. outputs.exposure must be exactly a || chain of
steps.<id>.outputs.exposure operands that includes the pending step's, and
outputs holds exactly one key that reads exposure in any case, spelled in lower
case; its other keys are allowed and their values are not read. The first
non-empty operand wins, so no operand before the pending one may be the id of a
step ahead of the pending step, nor of a step after it other than the one with
the id harness, which judges the listings and writes found or none; operands
after the pending one are not judged.

The harness step after the pending step is read further, because outputs.exposure
trusts it ahead of pending. It must be a run step, never uses, with no key but
name, id, if and run: shell would replace the interpreter that runs the write,
and env can set BASH_ENV or ENV, which run a script before the run does, so both
are refused with the rest. Its whole run, once spaces and newlines around it are
dropped, must be HARNESS_RUN, the one fixed form: the script runs with
GITHUB_OUTPUT unset, so it writes no exposure value; exit 0 and exit 4 write
none, exit 3 writes found, any other status writes nothing, and the step exits
with the script's status. A run that writes nothing falls through to pending,
the value ADR 024 item 3 gives to a run that ended before every listing was
judged, so bots-stopped-file files it.

The workflow's concurrency.cancel-in-progress, when it has one, must be a plain
false, and the check ends otherwise: a newer run cancels an older run and every
job in it, bot-proofs included, before that job's exposure is filed.

A step after the pending step may carry an if only when its run, once spaces and
newlines around it are dropped, is in TEARDOWN_RUNS and it has no key but name,
if and run. Any other if, always(), !cancelled() and failure() included, may
run the step after a cancel or failure that came before the pending write
completed, so a bot could start with no pending written.

With no pending step the chain and outputs key rules still apply, and the check
passes when every step is on the allowlist; no operand is judged.

Limits: PyYAML stands in for GitHub's parser and is not compared with it. Not
read: the contents of other jobs, whose ids are read as keys of jobs; the values
under workflow name, on, permissions and concurrency, bar cancel-in-progress, and of workflow env
variables; a job's name, needs, if, runs-on, timeout-minutes and permissions;
the values of outputs keys other than exposure; if values on any step, ahead
of the pending step or after it, and the continue-on-error value of a step
ahead of it unless its run is PENDING_WRITE and it has an id; a script a step
calls. A step after the pending step is read as a mapping and its id meets the
id rules above. Only whether it has an if is read, never the value. Its keys
are judged only when it has an if, and then its run is read and it may hold
only name, if and run. Without an if its run, env, with and continue-on-error
are not read, nor is what it writes to its outputs, except for the harness step
above. What deploy/bot-proofs.sh does is not read, and the form above only
withholds GITHUB_OUTPUT from it (riftal-infra#1240, riftal-infra#1259,
riftal-infra#1262).
"""

import re
import sys

import yaml

PENDING_WRITE = "printf 'exposure=pending\\n' >> \"$GITHUB_OUTPUT\""
RUN_LINES = frozenset(
    r"""
. .github/scripts/bot-proofs-checks.sh
runner_tools_present
wslconfig_bridged
bots_stopped_clear
printf 'exposure=no-bots\n' >> "$GITHUB_OUTPUT"
if ! address="$(eth0_address)"; then
printf '%s\n' "$address"
exit 1
fi
printf 'eth0 address %s\n' "$address"
printf 'address=%s\n' "$address" >> "$GITHUB_OUTPUT"
bash .github/scripts/ci-docker-label.sh
. images/devtools-image.sh
devtools_extract "$RUNNER_TEMP/riftal-devtools"
bash .github/scripts/ci-container-sweep.sh
""".split("\n")
)
TEARDOWN_RUNS = frozenset({"bash .github/scripts/ci-container-sweep.sh"})
TEARDOWN_KEYS = {"name", "if", "run"}
HARNESS_RUN = r"""status=0
env -u GITHUB_OUTPUT bash deploy/bot-proofs.sh || status=$?
case "$status" in
  0|4) printf 'exposure=none\n' >> "$GITHUB_OUTPUT" ;;
  3) printf 'exposure=found\n' >> "$GITHUB_OUTPUT" ;;
esac
exit "$status"
""".strip()
HARNESS_ID = "harness"
HARNESS_KEYS = {"name", "id", "if", "run"}
WORKFLOW_KEYS = {"name", "on", "permissions", "concurrency", "env", "jobs"}
JOB_KEYS = {"name", "needs", "if", "runs-on", "timeout-minutes", "permissions", "outputs", "steps"}
STEP_KEYS = {"name", "id", "uses", "if", "continue-on-error", "run", "env", "with"}
PENDING_KEYS = {"name", "id", "run", "continue-on-error"}
STEP_ID = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
OPERAND = r"steps\.(" + STEP_ID.pattern + r")\.outputs\.exposure"
CHAIN = re.compile(r"\$\{\{ " + OPERAND + r"( \|\| " + OPERAND + r")* \}\}")
CHECKOUT = re.compile(r"actions/checkout@[0-9a-f]{40}")
NOT_TEXT = re.compile(r"[^\x20-\x7e\n]")


class Refuse(Exception):
    pass


def parse(text):
    if re.search(r"[^\x20-\x7e\r\n]", text):
        raise Refuse("it holds a character outside printable ASCII, which YAML parsers read differently")
    try:
        for event in yaml.parse(text, Loader=yaml.SafeLoader):
            if getattr(event, "anchor", None) or getattr(event, "tag", None):
                raise Refuse(f"line {event.start_mark.line + 1} has an anchor, alias or tag")
        return yaml.compose(text, Loader=yaml.SafeLoader)
    except yaml.YAMLError as err:
        raise Refuse("PyYAML cannot read it: " + " ".join(str(err).split())) from err


def mapping(node, what):
    if not isinstance(node, yaml.MappingNode) or not all(isinstance(key, yaml.ScalarNode) for key, _ in node.value):
        raise Refuse(f"{what} is not a mapping with scalar keys")
    for key, _ in node.value:
        if NOT_TEXT.search(key.value):
            raise Refuse(f"a key of {what} holds a character outside printable ASCII and newline")
    out = {key.value: value for key, value in node.value}
    if len(out) != len(node.value):
        raise Refuse(f"{what} repeats a key")
    return out


def scalar(node, what):
    if not isinstance(node, yaml.ScalarNode):
        raise Refuse(f"{what} is not a scalar")
    if NOT_TEXT.search(node.value):
        raise Refuse(f"{what} holds a character outside printable ASCII and newline")
    return node.value


def allow(keys, allowed, what):
    for key in keys:
        if key not in allowed:
            raise Refuse(f"{what} {key} is not on the allowlist")


def stray(step, allowed):
    return next((f"it has the key {key}" for key in step if key not in allowed), None)


def submap(step, key):
    return mapping(step[key], key) if key in step else {}


def pending_problem(step, run):
    flag = step.get("continue-on-error")
    if run.strip(" \n") != PENDING_WRITE:
        return "its run is not that single write"
    if "id" not in step:
        return "it has no id"
    if flag is not None and (scalar(flag, "continue-on-error") != "false" or flag.style is not None):
        return "its continue-on-error is not a plain false"
    return stray(step, PENDING_KEYS)


def ahead_problem(step, run):
    if why := stray(step, STEP_KEYS):
        return why
    if "uses" in step:
        if "run" in step or "env" in step:
            return "it has uses beside run or env"
        if not CHECKOUT.fullmatch(scalar(step["uses"], "uses")):
            return f"it uses {step['uses'].value}, which is not actions/checkout by commit sha"
        entries = {k: scalar(v, k) for k, v in submap(step, "with").items()}
        return None if entries == {"persist-credentials": "false"} else "its with is not exactly persist-credentials: false"
    if "with" in step:
        return "it has a with block and is not actions/checkout"
    if "run" not in step:
        return "it has no run"
    bad = next((k for k, v in submap(step, "env").items() if (k, scalar(v, k)) != ("GITHUB_TOKEN", "${{ github.token }}")), None)
    if bad:
        return f"it has the env variable {bad}"
    bad = next((text for text in (line.strip(" ") for line in run.split("\n")) if text and not text.startswith("#") and text not in RUN_LINES), None)
    return bad and f"the run line '{bad}' is not on the allowlist"


def after_problem(step):
    if "if" not in step:
        return None
    run = scalar(step["run"], "run") if "run" in step else ""
    if run.strip(" \n") not in TEARDOWN_RUNS:
        return "it has an if, which may run it after a cancel or failure that came before the pending write completed, and it is not a teardown step"
    return stray(step, TEARDOWN_KEYS)


def harness_problem(step):
    if "uses" in step:
        return f"it is the {HARNESS_ID} step and uses an action, whose outputs are not read"
    if why := stray(step, HARNESS_KEYS):
        return f"it is the {HARNESS_ID} step and {why}"
    run = scalar(step["run"], "run") if "run" in step else ""
    if run.strip(" \n") != HARNESS_RUN:
        return f"it is the {HARNESS_ID} step and its run is not the one fixed form: {HARNESS_RUN!r}"
    return None


def judge(path, job):
    errors = []
    with open(path, encoding="utf-8", newline="") as handle:
        top = mapping(parse(handle.read()), "the workflow")
    allow(top, WORKFLOW_KEYS, "top-level key")
    cancel = submap(top, "concurrency").get("cancel-in-progress")
    if cancel is not None and (scalar(cancel, "cancel-in-progress") != "false" or cancel.style is not None):
        raise Refuse("concurrency.cancel-in-progress is not a plain false, so a newer run cancels this one before its exposure is filed")
    allow(submap(top, "env"), {"HADOLINT_VERSION", "HADOLINT_SHA256"}, "workflow env variable")
    jobs = submap(top, "jobs")
    if job not in jobs:
        raise Refuse(f"no job {job}")
    if [name for name in jobs if name.lower() == job.lower()] != [job]:
        raise Refuse(f"another job id differs from {job} only by case")
    body = mapping(jobs[job], f"the {job} job")
    allow(body, JOB_KEYS, "job key")
    outputs = submap(body, "outputs")
    if [key for key in outputs if key.lower() == "exposure"] != ["exposure"]:
        raise Refuse("outputs must hold exactly one key spelled exposure")
    expr = scalar(outputs["exposure"], "outputs.exposure")
    if not isinstance(body.get("steps"), yaml.SequenceNode):
        raise Refuse("steps is not a sequence")
    ids = {}
    pending_at = pending_id = None
    for number, node in enumerate(body["steps"].value, 1):
        step = mapping(node, f"step {number}")
        if "id" in step:
            ident = scalar(step["id"], "id")
            if not STEP_ID.fullmatch(ident):
                raise Refuse(f"step {number} has the id '{ident}', which is not letters, digits, _ and -")
            if ident.lower() in ids:
                raise Refuse(f"step {number} repeats the id {ident}, which GitHub reads without regard to case")
            ids[ident.lower()] = number
        if pending_at:
            if "id" in step and ident.lower() == HARNESS_ID and (why := harness_problem(step)):
                errors.append(f"step {number} is after the exposure=pending write: {why}")
            elif why := after_problem(step):
                errors.append(f"step {number} is after the exposure=pending write: {why}")
            continue
        run = scalar(step["run"], "run") if "run" in step else ""
        label = scalar(step["name"], "name") if "name" in step else "unnamed"
        if (why := pending_problem(step, run)) is None:
            pending_at, pending_id = number, ident.lower()
        elif "exposure=pending" in run:
            errors.append(f"step {number} ({label}) writes exposure=pending but is not one unconditional step with an id whose whole run is: {PENDING_WRITE}, with no key but name, id, run and continue-on-error, which is accepted only as a plain false: {why}")
        elif why := ahead_problem(step, run):
            errors.append(f"step {number} ({label}) is ahead of any exposure=pending write and is not on the allowlist, so it may start a bot before the write completes: {why}")

    if not CHAIN.fullmatch(expr):
        errors.append(f"outputs.exposure is not exactly a || chain of steps.<id>.outputs.exposure operands: {expr}")
    elif pending_id:
        operands = [name.lower() for name in re.findall(OPERAND, expr)]
        if pending_id not in operands:
            errors.append(f"outputs.exposure does not read steps.{pending_id}.outputs.exposure")
        else:
            for name in operands[: operands.index(pending_id)]:
                if ids.get(name, pending_at) < pending_at:
                    errors.append(f"outputs.exposure reads step {name}, which completes before the pending step, so exposure=pending can never be the output")
                elif ids.get(name, pending_at) > pending_at and name != HARNESS_ID:
                    errors.append(f"outputs.exposure reads step {name} before the pending step, and that step runs after the pending write and is not the {HARNESS_ID} step, so it can hide pending while bots run")
    if pending_id:
        return errors, f"{job}: {pending_at - 1} step(s) ahead of step {pending_at} (id {pending_id}) writing exposure=pending, all on the allowlist, and outputs.exposure reads it"
    return errors, f"{job}: all steps on the allowlist, none can start a bot and no exposure=pending write is needed yet"


def check(path, job="bot-proofs"):
    try:
        return judge(path, job)
    except OSError as err:
        return [f"cannot read {path} to check exposure=pending comes first: {err}"], ""
    except Refuse as err:
        return [f"cannot place the {job} job: {err}"], ""


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else ".github/workflows/ci.yml"
    errors, summary = check(path, sys.argv[2] if len(sys.argv) > 2 else "bot-proofs")
    print(*[f"::error::{path}: {error}" for error in errors] or [summary], sep="\n")
    sys.exit(1 if errors else 0)
