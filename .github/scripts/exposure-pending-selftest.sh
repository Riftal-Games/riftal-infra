#!/usr/bin/env bash
# Proves exposure-pending-order.sh can fail. ci.yml passes it today because its
# bot-proofs job starts no bot, so a check that always passed would look the
# same. Each mutant below is the good fixture with one defect, and must be
# refused for its own reason. Reads files only and starts no container.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$dir/exposure-pending-order.sh"
good="${dir%/scripts}/ci-fixtures/good/exposure-pending/pending-first.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
ran=0
expected=15

# $1 label, $2 pass or fail, $3 text the output must hold, $4 workflow file
expect() {
  local out rc=0
  ran=$((ran + 1))
  out="$(bash "$check" "$4" 2>&1)" || rc=$?
  if grep -qF -- "$3" <<<"$out" &&
    { { [ "$2" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$2" = fail ] && [ "$rc" -ne 0 ]; }; }; then
    printf '  ok    %s, %s\n' "$1" "$2"
  else
    printf '::error::%s: want %s with "%s", got exit %s: %s\n' "$1" "$2" "$3" "$rc" "$out"
    failures=$((failures + 1))
  fi
}

# $1 mutant name, $2 sed script, $3 reason, applied to the good fixture. A
# mutant that equals the fixture would pass for the wrong reason.
mutant() {
  local file="$work/$1.yml"
  sed -e "$2" "$good" > "$file"
  if cmp -s "$good" "$file"; then
    printf '::error::mutant %s did not change the fixture\n' "$1"
    failures=$((failures + 1))
    ran=$((ran + 1))
    return
  fi
  expect "mutant $1" fail "$3" "$file"
}

expect "good fixture" pass "all on the allowlist, and outputs.exposure reads it" "$good"
expect "the real ci.yml" pass "all on the allowlist" "${dir%/.github/scripts}/.github/workflows/ci.yml"

mutant pending-missing '/id: pending/,/GITHUB_OUTPUT/d;/- name: Exposure, bots may start/d' \
  "step 4 (Harness) is ahead of any exposure=pending write"
mutant pending-after-bot-step \
  '/- name: Exposure, bots may start/,/GITHUB_OUTPUT/{H;d};/bash start-first-bot.sh/{G;s/\n\n*/\n/}' \
  "step 4 (Harness) is ahead of any exposure=pending write"
mutant pending-conditional 's/^        id: pending/        id: pending\n        if: always()/' \
  "step 4 (Exposure, bots may start) writes exposure=pending but is not one unconditional step"
mutant pending-continue-on-error 's/^        id: pending/        id: pending\n        continue-on-error: true/' \
  "step 4 (Exposure, bots may start) writes exposure=pending but is not one unconditional step"
mutant pending-no-id '/^        id: pending/d' \
  "writes exposure=pending but is not one unconditional step with an id"
mutant pending-with-bot-start '/exposure=pending/s/run: /run: bash start-first-bot.sh; /'   "writes exposure=pending but is not one unconditional step"
mutant pending-output-not-read 's/ || steps.pending.outputs.exposure//' \
  "outputs.exposure does not read steps.pending.outputs.exposure"
mutant pending-output-shadowed 's/exposure: .*/exposure: ${{ steps.exposure.outputs.exposure || steps.pending.outputs.exposure }}/' \
  "outputs.exposure reads step exposure, which completes before the pending step"
mutant unlisted-step-before-pending '/- name: Exposure, no bot has started/i\      - name: Start something\n        run: node run-bot.js\n' \
  "step 3 (Start something) is ahead of any exposure=pending write"
mutant unlisted-action-before-pending '/- name: Exposure, no bot has started/i\      - uses: some/action@11d5960a326750d5838078e36cf38b85af677262\n' \
  "is ahead of any exposure=pending write and is not on the allowlist"
mutant no-job-output '/^    outputs:/,/^$/d' \
  "has no outputs.exposure for bots-stopped-file to read"

real="${dir%/.github/scripts}/.github/workflows/ci.yml"
awk '
  { print }
  /# steps.eth0.outputs.address is what every socket listing is judged/ && !done {
    print ""
    print "      - name: Start the first bot"
    print "        run: node devtools/bot.js"
    done = 1
  }' "$real" > "$work/real-with-bot.yml"
if cmp -s "$real" "$work/real-with-bot.yml"; then
  printf '::error::the bot step was not inserted into a copy of ci.yml\n'
  failures=$((failures + 1))
  ran=$((ran + 1))
else
  expect "ci.yml with a bot step and no pending step" fail "step 9 (Start the first bot) is ahead of any exposure=pending write" "$work/real-with-bot.yml"
fi

expect "a missing workflow" fail "cannot read" "$work/absent.yml"

if [ "$ran" -ne "$expected" ]; then
  printf '::error::ran %s of %s exposure-pending assertions\n' "$ran" "$expected"
  exit 1
fi
[ "$failures" -eq 0 ] || exit 1
printf 'exposure-pending-order.sh refuses every mutant for its own reason\n'
