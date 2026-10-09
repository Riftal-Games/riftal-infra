#!/usr/bin/env bash
# Proves job-timeouts.sh can refuse a workflow. Its only real input is ci.yml,
# which passes, so without these fixtures a check that always passes would look
# the same. Reads files only and starts no container.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="${dir%/scripts}/ci-fixtures"
# shellcheck source=job-timeouts.sh
. "$dir/job-timeouts.sh"
failures=0
ran=0
# Every assertion below must run. A harness that quietly runs fewer and still
# prints its closing line is the exact failure it exists to catch.
expected=5

# Each refusal must name its own reason, so a fixture refused for a defect it
# was not written for does not count.
expect() {
  local file="$fixtures/$1" status="$2" reason="$3" out rc
  ran=$((ran + 1))
  out="$(job_timeouts_under "$file" 1200)"
  rc=$?
  if [ "$out" = "$reason" ] &&
    { { [ "$status" = pass ] && [ "$rc" -eq 0 ]; } ||
      { [ "$status" = fail ] && [ "$rc" -ne 0 ]; }; }; then
    printf '  ok    %s, %s: %s\n' "$1" "$status" "$out"
  else
    printf "::error::%s: want %s with '%s', got exit %s with '%s'\n" "$1" "$status" "$reason" "$rc" "$out"
    failures=$((failures + 1))
  fi
}

f="$fixtures/good/job-timeouts/two-jobs.yml"
expect good/job-timeouts/two-jobs.yml pass \
  "every one of 2 job(s) in $f times out within 19 minutes, under 20"
f="$fixtures/bad/job-timeouts/missing.yml"
expect bad/job-timeouts/missing.yml fail "$f: 2 job(s), 1 with a job-level timeout-minutes"
f="$fixtures/bad/job-timeouts/step-level.yml"
expect bad/job-timeouts/step-level.yml fail "$f: 1 job(s), 0 with a job-level timeout-minutes"
f="$fixtures/bad/job-timeouts/expression.yml"
expect bad/job-timeouts/expression.yml fail "$f: 1 job-level timeout-minutes not a plain number"
f="$fixtures/bad/job-timeouts/at-cutoff.yml"
expect bad/job-timeouts/at-cutoff.yml fail "$f: longest job timeout is 20 minutes, not under 20"

if [ "$ran" -ne "$expected" ]; then
  printf '::error::ran %s of %s job-timeouts assertions\n' "$ran" "$expected"
  exit 1
fi
[ "$failures" -eq 0 ] || exit 1
printf 'job-timeouts.sh refuses every bad fixture for its own reason\n'
