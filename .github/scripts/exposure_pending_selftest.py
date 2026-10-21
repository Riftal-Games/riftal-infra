#!/usr/bin/env python3
"""Proves exposure_pending_order.py can fail. Each case is the good fixture, or
ci.yml for a name starting ci.yml, with edits. It must be refused for its own
reason, or accepted where YAML reads the edit as the same value or the edit is
allowed (want starting with =). Reads files only. Needs an interpreter with
PyYAML.
"""

import importlib.util
import pathlib
import sys
import tempfile

sys.dont_write_bytecode = True
here = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("order", here / "exposure_pending_order.py")
order = importlib.util.module_from_spec(spec)
spec.loader.exec_module(order)

WRITE = "printf 'exposure=pending\\n' >> \"$GITHUB_OUTPUT\""
PENDING = f"      - name: Exposure, bots may start\n        id: pending\n        run: {WRITE}\n\n"
RUN = "".join(f"          {line}\n" for line in order.HARNESS_RUN.split("\n"))
RUN_END = '          exit "$status"\n'
BOT = "      - name: Harness\n        id: harness\n        run: |\n" + RUN
EXPR = "${{ steps.harness.outputs.exposure || steps.pending.outputs.exposure || steps.exposure.outputs.exposure }}"
EXPR_LINE = f"      exposure: {EXPR}\n"
SHADOWED = "      exposure: ${{ steps.exposure.outputs.exposure || steps.pending.outputs.exposure }}\n"
PEND_ID = "        id: pending\n"
NOBOTS_ID = "        id: exposure\n"
NOBOTS = "      - name: Exposure, no bot has started\n" + NOBOTS_ID + "        run: printf 'exposure=no-bots\\n' >> \"$GITHUB_OUTPUT\"\n"
RUNNER = "      - name: Runner has /usr/bin/jq and /usr/bin/curl\n"
SWEEP = "      - name: Remove this job's containers\n        if: always()\n        run: bash .github/scripts/ci-container-sweep.sh\n"
LATE = "      - name: Late write\n        id: late\n        run: printf 'exposure=no-bots\\n' >> \"$GITHUB_OUTPUT\"\n"
HARNESS_ID = "        id: harness\n"
OUT = '"$GITHUB_OUTPUT"'
HARNESS_KEY = "the harness step and it has the key "
HARNESS_FORM = "the harness step and its run is not the one fixed form"
SHA = "11d5960a326750d5838078e36cf38b85af677262"
PENDING_BAD = "which is accepted only as a plain false"
SHADOW_WANT = "outputs.exposure reads step exposure, which completes before the pending step"
AHEAD = "is ahead of any exposure=pending write and is not on the allowlist"
CHAIN_WANT = "outputs.exposure is not exactly a || chain"
ONE_KEY = "outputs must hold exactly one key spelled exposure"
AFTER_IF = "step 5 is after the exposure=pending write: it has an if"
SWEEP_WANT = "step 6 is after the exposure=pending write: it has an if"
LATE_WANT = "outputs.exposure reads step late before the pending step"
SHA_WANT = "which is not actions/checkout by commit sha"
PASS = "=all on the allowlist"
CREDS = "        with:\n          persist-credentials: false\n"
CREDS_WANT = "its with is not exactly persist-credentials: false"
NOT_PRINTABLE = "outside printable ASCII and newline"
FLOW_NOBOTS = "      - {name: Exposure, id: 'exposure', run: \"printf 'exposure=no-bots\\\\n' >> \\\"$GITHUB_OUTPUT\\\"\"}\n"


def rep(*pairs):
    def edit(text):
        for old, new in zip(pairs[::2], pairs[1::2]):
            assert old in text, f"edit target missing: {old!r}"
            text = text.replace(old, new, 1)
        return text
    return edit


def add(anchor, extra):
    return rep(anchor, anchor + extra)


def dq(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def harness(*lines):
    return rep(RUN_END, "".join(f"          {line}\n" for line in lines) + RUN_END)


def shadow(id_line):
    return rep(EXPR_LINE, SHADOWED, NOBOTS_ID, id_line)


cases = [
    ("pending-missing", rep(PENDING, ""), "step 4 (Harness) " + AHEAD),
    ("pending-after-bot-step", rep(PENDING + BOT, BOT + "\n" + PENDING.rstrip("\n") + "\n"), "step 4 (Harness) " + AHEAD),
    ("pending-quoted-if", add(PEND_ID, '        "if": false\n'), PENDING_BAD + ": it has the key if"),
    ("pending-shell", add(PEND_ID, "        shell: node devtools/bot.js {0}\n"), PENDING_BAD + ": it has the key shell"),
    ("pending-continue-on-error", add(PEND_ID, "        continue-on-error: true\n"), "its continue-on-error is not a plain false"),
    ("pending-continue-on-error-quoted", add(PEND_ID, "        continue-on-error: 'false'\n"), "its continue-on-error is not a plain false"),
    ("pending-no-id", rep(PEND_ID, ""), PENDING_BAD + ": it has no id"),
    ("pending-with-bot-start", rep("run: printf 'exposure=pending", "run: bash start-first-bot.sh; printf 'exposure=pending"), "its run is not that single write"),
    ("pending-folded-run", rep(f"run: {WRITE}\n\n", f"run: >\n          {WRITE}\n          node run-bot.js\n\n"), "its run is not that single write"),
    ("pending-id-commented", rep(PEND_ID, "        id: pending # c\n"), PASS),
    ("pending-output-not-read", rep(" || steps.pending.outputs.exposure", ""), "outputs.exposure does not read steps.pending.outputs.exposure"),
    ("outputs-shadowed", rep(EXPR_LINE, SHADOWED), SHADOW_WANT),
    ("outputs-shadowed-id-single-quoted", shadow("        id: 'exposure'\n"), SHADOW_WANT),
    ("outputs-shadowed-id-commented", shadow("        id: exposure # no-bots\n"), SHADOW_WANT),
    ("outputs-shadowed-id-quoted-key", shadow('        "id" : exposure\n'), SHADOW_WANT),
    ("outputs-shadowed-id-upper-case", shadow("        id: EXPOSURE\n"), SHADOW_WANT),
    ("outputs-shadowed-operand-upper-case", rep(EXPR_LINE, SHADOWED.replace("steps.exposure", "steps.EXPOSURE")), SHADOW_WANT),
    ("outputs-shadowed-id-flow-step", rep(EXPR_LINE, SHADOWED, NOBOTS, FLOW_NOBOTS), SHADOW_WANT),
    ("ids-differ-by-case", rep("id: harness", "id: Pending"), "repeats the id Pending, which GitHub reads without regard to case"),
    ("id-with-a-dot", rep("id: harness", "id: harness.x"), "which is not letters, digits, _ and -"),
    ("after-pending-if-always", add(HARNESS_ID, "        if: always()\n"), AFTER_IF),
    ("after-pending-if-not-cancelled", add(HARNESS_ID, "        if: ${{ !cancelled() }}\n"), AFTER_IF),
    ("after-pending-if-failure", add(HARNESS_ID, "        if: failure()\n"), AFTER_IF),
    ("after-pending-if-quoted-key", add(HARNESS_ID, '        "if" : always()\n'), AFTER_IF),
    ("after-pending-if-on-uses-step", add(BOT, f"\n      - uses: actions/checkout@{SHA}\n        if: always()\n"), SWEEP_WANT),
    ("after-pending-teardown-with-if", add(BOT, "\n" + SWEEP), PASS),
    ("after-pending-teardown-extended", add(BOT, "\n" + SWEEP.replace("sweep.sh", "sweep.sh; node devtools/bot.js")), SWEEP_WANT),
    ("after-pending-teardown-shell", add(BOT, "\n" + SWEEP.replace("        run:", "        shell: node devtools/bot.js {0}\n        run:")), "step 6 is after the exposure=pending write: it has the key shell"),
    ("after-pending-teardown-env", add(BOT, "\n" + SWEEP.replace("        run:", "        env: {BASH_ENV: devtools/start-bot.sh}\n        run:")), "step 6 is after the exposure=pending write: it has the key env"),
    ("after-pending-teardown-other-script", add(BOT, "\n" + SWEEP.replace("ci-container-sweep", "start-bots")), SWEEP_WANT),
    ("after-pending-late-writes-earlier-output", rep(EXPR_LINE, EXPR_LINE.replace("${{ ", "${{ steps.late.outputs.exposure || "), BOT, BOT + "\n" + LATE), LATE_WANT),
    ("after-pending-harness-renamed", rep("id: harness", "id: judge", "steps.harness", "steps.judge"), "outputs.exposure reads step judge before the pending step"),
    ("harness-writes-no-bots", harness(f"printf 'exposure=no-bots\\n' >> {OUT}"), HARNESS_FORM),
    ("harness-write-appended-with-bot", harness(f"node devtools/bot.js; printf 'exposure=none\\n' >> {OUT}"), HARNESS_FORM),
    ("harness-shell-writes-no-bots", add(HARNESS_ID, "        shell: bash -c \"printf 'exposure=no-bots\\n' >> \\\"$GITHUB_OUTPUT\\\"\" {0}\n"), HARNESS_KEY + "shell"),
    ("harness-env-bash-env", add(HARNESS_ID, "        env: {BASH_ENV: devtools/write-no-bots.sh}\n"), HARNESS_KEY + "env"),
    ("harness-uses-action", rep("        run: |\n" + RUN, f"        uses: some/action@{SHA}\n"), "the harness step and uses an action"),
    ("harness-found-then-none", harness(f"printf 'exposure=found\\n' >> {OUT}", f"printf 'exposure=none\\n' >> {OUT}"), HARNESS_FORM),
    ("harness-none-before-the-script", rep("          status=0\n", f"          printf 'exposure=none\\n' >> {OUT}\n          status=0\n"), HARNESS_FORM),
    ("harness-keeps-github-output", rep("env -u GITHUB_OUTPUT ", ""), HARNESS_FORM),
    ("harness-other-form", rep("        run: |\n" + RUN, "        run: bash start-first-bot.sh\n"), HARNESS_FORM),
    ("cancel-in-progress-true", rep("jobs:", "concurrency:\n  group: g\n  cancel-in-progress: true\n\njobs:"), "concurrency.cancel-in-progress is not a plain false"),
    ("cancel-in-progress-quoted-false", rep("jobs:", "concurrency:\n  group: g\n  cancel-in-progress: 'false'\n\njobs:"), "concurrency.cancel-in-progress is not a plain false"),
    ("cancel-in-progress-false", rep("jobs:", "concurrency:\n  group: g\n  cancel-in-progress: false\n\njobs:"), PASS),
    ("outputs-continuation", add(EXPR_LINE, "        bots running\n"), CHAIN_WANT),
    ("outputs-folded-continuation", rep(EXPR_LINE, "      exposure: >\n        " + EXPR + "\n        bots running\n"), CHAIN_WANT),
    ("outputs-literal-operand", rep(EXPR_LINE, "      exposure: ${{ 'no-bots' || steps.pending.outputs.exposure }}\n"), CHAIN_WANT),
    ("outputs-key-also-upper-case", add(EXPR_LINE, "      Exposure: x\n"), ONE_KEY),
    ("outputs-none", rep("    outputs:\n" + EXPR_LINE, ""), ONE_KEY),
    ("outputs-commented", rep(EXPR_LINE, EXPR_LINE.rstrip("\n") + " # c\n"), PASS),
    ("unlisted-step-before-pending", rep(NOBOTS, "      - name: Start something\n        run: node run-bot.js\n\n" + NOBOTS), "step 3 (Start something) " + AHEAD),
    ("flow-style-step", rep(NOBOTS, "      - {name: Start, run: node run-bot.js}\n\n" + NOBOTS), "the run line 'node run-bot.js' is not on the allowlist"),
    ("unlisted-action", rep(NOBOTS, f"      - uses: some/action@{SHA}\n\n" + NOBOTS), SHA_WANT),
    ("checkout-by-tag", rep("checkout@" + SHA, "checkout@v4"), SHA_WANT),
    ("checkout-persist-credentials-true", rep("persist-credentials: false", "persist-credentials: true"), CREDS_WANT),
    ("checkout-no-with", rep(CREDS, ""), CREDS_WANT),
    ("checkout-with-ref", add(CREDS, "          ref: main\n"), CREDS_WANT),
    ("checkout-with-env", rep(CREDS, "        env:\n          NODE_OPTIONS: --require ./x.js\n" + CREDS), "it has uses beside run or env"),
    ("checkout-with-run", rep("        with:\n          persist", "        run: node devtools/bot.js\n        with:\n          persist"), "it has uses beside run or env"),
    ("with-on-run-step", add(RUNNER, "        with:\n          x: y\n"), "it has a with block and is not actions/checkout"),
    ("comment-line-in-run", add("          runner_tools_present\n", "          # not a command\n"), PASS),
    ("bad-middle-run-line", add("          runner_tools_present\n", "          node run-bot.js\n"), "the run line 'node run-bot.js' is not on the allowlist"),
    ("plain-run-continuation", add("exposure=no-bots\\n' >> \"$GITHUB_OUTPUT\"\n", "          && node devtools/bot.js\n"), "is not on the allowlist"),
    ("shell-quoted-key", add(RUNNER, '        "shell" : node devtools/bot.js {0}\n'), "it has the key shell"),
    ("env-bash-env", add(RUNNER, "        env: {BASH_ENV: devtools/start-bot.sh}\n"), "it has the env variable BASH_ENV"),
    ("env-token-value", add(RUNNER, "        env:\n          GITHUB_TOKEN: $(node devtools/bot.js)\n"), "it has the env variable GITHUB_TOKEN"),
    ("duplicate-run-key", add(RUNNER, "        run: true\n        run: node run-bot.js\n"), "repeats a key"),
    ("anchor", rep(RUNNER, "      - name: &n Runner\n"), "has an anchor, alias or tag"),
    ("alias", rep("id: harness", "id: *n"), "has an anchor, alias or tag"),
    ("tag", rep(RUNNER, "      - name: !!str Runner\n"), "has an anchor, alias or tag"),
    ("ahead-run-escaped-vertical-tab", rep(NOBOTS, '      - run: "\\v# || node devtools/bot.js"\n\n' + NOBOTS), NOT_PRINTABLE),
    ("ahead-run-escaped-unicode-space", rep(NOBOTS, '      - run: "\\u2003# || node devtools/bot.js"\n\n' + NOBOTS), NOT_PRINTABLE),
    ("pending-run-escaped-trailing-vertical-tab", rep(f"run: {WRITE}\n\n", "run: " + dq(WRITE)[:-1] + '\\v"\n\n'), NOT_PRINTABLE),
    ("outputs-key-long-s", add(EXPR_LINE, '      "expo\\u017fure": no-bots\n'), "a key of outputs holds a character " + NOT_PRINTABLE),
    ("outputs-key-escaped-control", add(EXPR_LINE, '      "note\\v": x\n'), "a key of outputs holds a character " + NOT_PRINTABLE),
    ("step-after-pending-key-dotless-i", add("        id: harness\n", '        "\\u0131d": x\n'), "a key of step 5 holds a character " + NOT_PRINTABLE),
    ("pending-id-upper-case", rep(PEND_ID, "        id: PENDING\n"), "=(id pending) writing"),
    ("ahead-step-no-run-or-uses", rep(NOBOTS, "      - name: Nothing\n\n" + NOBOTS), "it has no run"),
    ("non-scalar-key", add(RUNNER, "        ? [a]\n        : b\n"), "is not a mapping with scalar keys"),
    ("mapping-wrong-kind", add(RUNNER, "        env: x\n"), "env is not a mapping with scalar keys"),
    ("scalar-wrong-kind", rep(EXPR_LINE, "      exposure: [x]\n"), "outputs.exposure is not a scalar"),
    ("steps-not-a-sequence", lambda text: text.split("    steps:\n")[0] + "    steps: x\n", "steps is not a sequence"),
    ("second-document", lambda text: text + "---\nname: other\n", "PyYAML cannot read it"),
    ("non-ascii", add("jobs:\n", "  # \u2028\n"), "outside printable ASCII"),
    ("job-services", add("    timeout-minutes: 15\n", "    services: {db: {image: x}}\n"), "job key services is not on the allowlist"),
    ("workflow-defaults", rep("jobs:", "defaults:\n  run:\n    shell: node devtools/bot.js {0}\n\njobs:"), "top-level key defaults is not on the allowlist"),
    ("workflow-env", rep("jobs:", "env:\n  BASH_ENV: devtools/start-bot.sh\n\njobs:"), "workflow env variable BASH_ENV is not on the allowlist"),
    ("job-id-by-case", lambda text: text + "  Bot-Proofs:\n    runs-on: x\n", "differs from bot-proofs only by case"),
    ("no-job", rep("  bot-proofs:", "  other:"), "no job bot-proofs"),
    ("crlf", lambda text: text.replace("\n", "\r\n"), PASS),
    ("good-fixture", None, PASS),
    ("ci.yml", None, "=8 step(s) ahead of step 9 (id pending) writing exposure=pending, all on the allowlist"),
]
sources = [here.parent / "ci-fixtures/good/exposure-pending/pending-first.yml", here.parent / "workflows/ci.yml"]

failures = 0
for name, edit, want in cases:
    base = sources[name.startswith("ci.yml")].read_text(encoding="utf-8")
    text = edit(base) if edit else base
    assert edit is None or text != base, f"{name}: the edit changed nothing"
    with tempfile.TemporaryDirectory() as tmp:
        file = pathlib.Path(tmp, "workflow.yml")
        file.write_bytes(text.encode("utf-8"))
        errors, summary = order.check(str(file))
    accepts = want.startswith("=")
    got = summary if accepts else "\n".join(errors)
    ok = bool(errors) != accepts and want.lstrip("=") in got
    print(f"  ok    {name}" if ok else f"::error::{name}: wanted '{want}', got: {got}")
    failures += not ok
errors, _ = order.check(str(here / "absent.yml"))
failures += not any("cannot read" in error for error in errors)
if failures:
    sys.exit(1)
print("exposure_pending_order.py refuses every mutant for its own reason")
