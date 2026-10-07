#!/usr/bin/env bash
# Self-test for container-limits.sh. Each fixture must give exactly the reports
# listed for it, and each real launch in .github/ must turn the check red once
# a limit is taken off it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$REPO_ROOT/.github/ci-fixtures"
LIMITS="$REPO_ROOT/.github/scripts/container-limits.sh"
FAILURES=0
PASSES=0
# Every assertion below must run. A harness that quietly runs fewer and still
# prints its closing line is the exact failure it exists to catch.
EXPECTED_ASSERTIONS=19
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); printf '%s\n' "$2"; }

# The check on $1 must exit $2 with exactly the reports that follow, each a
# line and its message, or a file, a line and its message in a directory. The
# whole set is compared, so a report that goes missing and one that appears
# where none belongs both turn it red.
expect_limits() {
  local path="$1" want_status="$2" sep=":" want got out status
  shift 2
  [ -d "$path" ] && sep="/"
  want="$(for w in "$@"; do printf '%s%s%s\n' "$path" "$sep" "$w"; done | sort)"
  out="$(bash "$LIMITS" "$path" 2>&1)"
  status=$?
  got="$(printf '%s\n' "$out" | grep -F "$path$sep" | sort)"
  if [ "$got" = "$want" ] && [ "$status" -eq "$want_status" ]; then
    pass "${path#"$REPO_ROOT"/} exits $want_status with exactly its $# report(s)"
  else
    fail "expected ${path#"$REPO_ROOT"/} to exit $want_status with exactly its $# report(s), exit $status" "$out"
  fi
}

# ci.yml passes no path, so the default scope decides what is checked. A bad
# launch planted in a workflow and in a script must both be reported.
expect_default_scope() {
  local tree="$scratch/tree" out status
  mkdir -p "$tree/.github/workflows" "$tree/.github/scripts"
  cp "$FIXTURES/bad/limits-after-image.sh" "$tree/.github/workflows/planted.yml"
  cp "$FIXTURES/bad/limits-after-image.sh" "$tree/.github/scripts/planted.sh"
  out="$(cd "$tree" && bash "$LIMITS" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF '.github/workflows/planted.yml:4:' \
    && printf '%s' "$out" | grep -qF '.github/scripts/planted.sh:4:'; then
    pass "the no-argument invocation checks .github/workflows and .github/scripts"
  else
    fail "expected the no-argument invocation to report both planted launches, exit $status" "$out"
  fi
}

# Takes one flag off the one launch in a copy of a real file, which must then
# be reported at that line, so the check is known to reach the real launch. No
# such launch, or two, fails: the launch moved and this self-test must follow.
expect_mutation_red() {
  local file="$REPO_ROOT/$1" flag="$2" missing="$3" copy="$scratch/${1##*/}" line out status
  # The bracket keeps this line from reading as a launch to either check.
  line="$(grep -n "docker[ ]run .* $flag " "$file" | cut -d: -f1)"
  if ! [[ "$line" =~ ^[0-9]+$ ]]; then
    fail "expected exactly one launch with $flag in $1, found lines: ${line:-none}" ""
    return
  fi
  sed "${line}s/ $flag / /" "$file" >"$copy"
  out="$(bash "$LIMITS" "$copy" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF "$copy:$line: a container started without $missing"; then
    pass "$1:$line without $flag is reported"
  else
    fail "expected $1:$line without $flag to be reported, exit $status" "$out"
  fi
}

started="a container started without"
nomem="$started -m/--memory"
neither="$started -m/--memory and --cpus"
verb="a docker command whose verb cannot be read"
reason="a container-limits line that is not exempt <reason>"
unused="a container-limits exemption with nothing under it to exempt"

expect_limits "$FIXTURES/good/limits.sh" 0
expect_limits "$FIXTURES/bad/limits-missing.sh" 1 "4: $nomem" "5: $started --cpus" "6: $neither" \
  "7: a container created without -m/--memory" "8: a container created without -m/--memory" \
  "9: $nomem" "10: $nomem" "11: $nomem" "12: $nomem" "13: $nomem" "14: $nomem" \
  "15: $started --cpus" "16: $nomem" "18: $neither"
expect_limits "$FIXTURES/bad/limits-after-image.sh" 1 "4: $neither" "5: $neither" "6: $neither"
expect_limits "$FIXTURES/bad/limits-quoted.sh" 1 \
  "4: $neither" "5: $neither" "6: $neither" "7: $neither" "8: $neither" "9: $neither"
expect_limits "$FIXTURES/bad/limits-verb.sh" 1 "4: $verb" "5: $verb" "6: $verb"
expect_limits "$FIXTURES/bad/limits-exempt-reason.sh" 1 "4: $reason" "6: $reason"
expect_limits "$FIXTURES/bad/limits-exempt-unused.sh" 1 "4: $unused" "6: $unused" "8: $unused" "11: $unused"
expect_limits "$FIXTURES/bad/limits-exempt-first.sh" 1 "5: $started --cpus"
expect_limits "$FIXTURES/bad/limits-carry" 1 "a.sh:1: $nomem" "a.sh:2: $unused" "b.sh:1: $nomem" "b.sh:2: $unused"
expect_limits "$FIXTURES/bad/limits-eof" 1 "a.sh:1: $nomem" "b.sh:1: $nomem"
# Nothing to check is a wrong path, never a clean tree. $scratch is still empty.
expect_limits "$scratch" 1
expect_limits "$scratch/no-such-path" 1
expect_default_scope
expect_mutation_red .github/workflows/ci.yml "-m 1g" "-m/--memory"
expect_mutation_red .github/workflows/ci.yml "--cpus 1" "--cpus"
expect_mutation_red .github/scripts/selftest.sh "-m 1g" "-m/--memory"
expect_mutation_red .github/scripts/selftest.sh "--cpus 1" "--cpus"
expect_mutation_red .github/scripts/ci-sweep-selftest.sh "-m 1g" "-m/--memory"
expect_mutation_red .github/scripts/ci-sweep-selftest.sh "--cpus 1" "--cpus"

ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '\n%s of %s assertions ran, so one did not run and cannot have passed\n' "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '\n%s assertion(s) failed. container-limits.sh has stopped discriminating.\n' "$FAILURES"
  exit 1
fi
printf '\nall %s assertions passed.\n' "$PASSES"
