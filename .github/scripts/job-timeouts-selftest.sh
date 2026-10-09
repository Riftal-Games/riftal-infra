#!/usr/bin/env bash
# Proves job-timeouts.sh can refuse a workflow. Its only real input is ci.yml,
# which passes, so without these fixtures a check that always passes would look
# the same. Reads files only and starts no container.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="${dir%/scripts}/ci-fixtures"
failures=0
ran=0
# Every assertion below must run. A harness that quietly runs fewer and still
# prints its closing line is the exact failure it exists to catch. One per
# fixture file, called workflows below them excluded, and one for a missing
# path, so dropping a case means deleting its fixture too.
expected=$(($(find "$fixtures/good/job-timeouts" "$fixtures/bad/job-timeouts"   -maxdepth 1 -type f -name '*.yml' | wc -l) + 1))

# Each refusal must name its own reason, so a fixture refused for a defect it
# was not written for does not count. A check that follows a call loop forever
# is cut off after 10 seconds, so it fails here and does not hang the job.
expect() {
  local file="$fixtures/$1" status="$2" reason="$3" out rc
  ran=$((ran + 1))
  # shellcheck disable=SC2016
  out="$(timeout 10 bash -c '. "$1" && job_timeouts_under "$2" 1200' _ "$dir/job-timeouts.sh" "$file")"
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
expect good/job-timeouts/two-jobs.yml pass   "every one of 2 job(s) in $f times out within 19 minutes, under 20"
f="$fixtures/good/job-timeouts/calls-local.yml"
expect good/job-timeouts/calls-local.yml pass   "every one of 2 job(s) in $f times out within 12 minutes, under 20"
f="$fixtures/bad/job-timeouts/missing.yml"
expect bad/job-timeouts/missing.yml fail "$f: job second has no job-level timeout-minutes"
f="$fixtures/bad/job-timeouts/step-level.yml"
expect bad/job-timeouts/step-level.yml fail "$f: job only has no job-level timeout-minutes"
f="$fixtures/bad/job-timeouts/expression.yml"
expect bad/job-timeouts/expression.yml fail "$f: job only has a timeout-minutes that is not a plain number"
f="$fixtures/bad/job-timeouts/at-cutoff.yml"
expect bad/job-timeouts/at-cutoff.yml fail "$f: job only times out at 20 minutes, not under 20"
f="$fixtures/bad/job-timeouts/leading-zero.yml"
expect bad/job-timeouts/leading-zero.yml fail "$f: job only times out at 23 minutes, not under 20"
f="$fixtures/bad/job-timeouts/paired.yml"
expect bad/job-timeouts/paired.yml fail "$f: job untimed has no job-level timeout-minutes"
f="$fixtures/bad/job-timeouts/neither.yml"
expect bad/job-timeouts/neither.yml fail "$f: job only has neither runs-on nor uses"
f="$fixtures/bad/job-timeouts/no-jobs.yml"
expect bad/job-timeouts/no-jobs.yml fail "$f: no job key indented two spaces under jobs"
f="$fixtures/bad/job-timeouts/calls-untimed.yml"
c="$fixtures/bad/job-timeouts/.github/workflows/called-untimed.yml"
expect bad/job-timeouts/calls-untimed.yml fail   "$f: job call: $c: job inner has no job-level timeout-minutes"
f="$fixtures/bad/job-timeouts/calls-remote.yml"
expect bad/job-timeouts/calls-remote.yml fail   "$f: job call uses Riftal-Games/riftal-infra/.github/workflows/ci.yml@ad88fa0a1b2c3d4e5f60718293a4b5c6d7e8f901, not a workflow in this checkout's .github/workflows, so its jobs cannot be read"
f="$fixtures/bad/job-timeouts/calls-loop.yml"
c="$fixtures/bad/job-timeouts/.github/workflows/loop.yml"
expect bad/job-timeouts/calls-loop.yml fail   "$f: job call: $c: job again calls $c, which is already in its own call chain"
f="$fixtures/bad/job-timeouts/calls-cycle.yml"
a="$fixtures/bad/job-timeouts/.github/workflows/cycle-a.yml"
b="$fixtures/bad/job-timeouts/.github/workflows/cycle-b.yml"
expect bad/job-timeouts/calls-cycle.yml fail   "$f: job call: $a: job next: $b: job back calls $a, which is already in its own call chain"
f="$fixtures/bad/job-timeouts/absent.yml"
expect bad/job-timeouts/absent.yml fail "cannot read $f to check every job times out"

if [ "$ran" -ne "$expected" ]; then
  printf '::error::ran %s of %s job-timeouts assertions\n' "$ran" "$expected"
  exit 1
fi
[ "$failures" -eq 0 ] || exit 1
printf 'job-timeouts.sh refuses every bad fixture for its own reason\n'
