#!/usr/bin/env bash
# Self-test for container-limits.sh. Each fixture must give exactly its reports,
# and each real launch in .github/ must turn the check red without a limit.
set -uo pipefail
# Runs expect_limits at the end of a pipe in this shell, where its count lands.
shopt -s lastpipe

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$REPO_ROOT/.github/ci-fixtures"
LIMITS="$REPO_ROOT/.github/scripts/container-limits.sh"
FAILURES=0
PASSES=0
# Every assertion below must run. A harness that quietly runs fewer and still
# prints its closing line is the exact failure it exists to catch.
EXPECTED_ASSERTIONS=15
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); printf '%s\n' "$2"; }
# Prints "<line>: <message>" for the message $1 at each line that follows.
at() { local m="$1" l; shift; for l in "$@"; do printf '%s: %s\n' "$l" "$m"; done; }

# The check on $1 must exit $2 with exactly the reports on stdin, each a line
# and its message, or a file, a line and its message in a directory. The whole
# set is compared, so a report that goes missing and one that appears where
# none belongs both turn it red.
expect_limits() {
  local path="$1" want_status="$2" sep=":" want got out status
  [ -d "$path" ] && sep="/"
  want="$(sed "s|^|$path$sep|" | sort)"
  out="$(bash "$LIMITS" "$path" 2>&1)"
  status=$?
  got="$(printf '%s\n' "$out" | grep -F "$path$sep" | sort)"
  if [ "$got" = "$want" ] && [ "$status" -eq "$want_status" ]; then
    pass "${path#"$REPO_ROOT"/} exits $want_status with exactly its reports"
  else
    fail "expected ${path#"$REPO_ROOT"/} to exit $want_status with exactly its reports, exit $status" "$out"
  fi
}

# Takes one flag off the one launch in a copy of a real file, which must then
# be reported at that line, so the check is known to reach the real launch. No
# such launch, or two, fails: the launch moved and this self-test must follow.
# The copy keeps its path and the check is given none, as ci.yml runs it, so
# the default scope is known to reach workflows and scripts.
expect_mutation_red() {
  local file="$REPO_ROOT/$1" flag="$2" missing="$3" copy="$scratch/tree/$1" line out status
  rm -rf "$scratch/tree"
  mkdir -p "$scratch/tree/.github/workflows" "$scratch/tree/.github/scripts"
  # The bracket keeps this line from reading as a launch to container-cleanup.sh.
  # container-limits: exempt a grep pattern that runs nothing
  line="$(grep -n "docker[ ]run .* $flag " "$file" | cut -d: -f1)"
  if ! [[ "$line" =~ ^[0-9]+$ ]]; then
    fail "expected exactly one launch with $flag in $1, found lines: ${line:-none}" ""
    return
  fi
  sed "${line}s/ $flag / /" "$file" >"$copy"
  out="$(cd "$scratch/tree" && bash "$LIMITS" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qxF "$1:$line: a container launch without $missing"; then
    pass "$1:$line without $flag is reported"
  else
    fail "expected $1:$line without $flag to be reported, exit $status" "$out"
  fi
}

launch="a container launch without"
unread="neither a plain limited run or create nor an allowlisted command"
reason="a container-limits line that is not exempt <reason>"
unused="a container-limits exemption with nothing under it to exempt"

expect_limits "$FIXTURES/good/limits.sh" 0 </dev/null
{
  at "$launch -m/--memory" 2 5 13
  at "$launch --cpus" 3
  at "$launch -m/--memory and --cpus" 4 6 7 8 10 11 12 14
} | expect_limits "$FIXTURES/bad/limits-missing.sh" 1
at "$unread" {2..42} | expect_limits "$FIXTURES/bad/limits-unread.sh" 1
at "a workflow job container or service, which takes no -m or --cpus" {2..8} |
  expect_limits "$FIXTURES/bad/limits-keys.yml" 1
{
  at "$reason" 2 4 16
  at "$unused" 6 8 10 18
  at "$launch -m/--memory and --cpus" 5 12 15
} | expect_limits "$FIXTURES/bad/limits-exempt.sh" 1
# b.bash and b, named without .sh, are read as scripts.
{
  at "$launch -m/--memory" a.sh:1 b.bash:1
  at "$unused" a.sh:2 b.bash:2
} | expect_limits "$FIXTURES/bad/limits-carry" 1
at "$launch -m/--memory" a.sh:1 b:1 | expect_limits "$FIXTURES/bad/limits-eof" 1
# Nothing to check is a wrong path, never a clean tree. $scratch is still empty.
expect_limits "$scratch" 1 </dev/null
expect_limits "$scratch/no-such-path" 1 </dev/null
for real in .github/workflows/ci.yml .github/scripts/selftest.sh .github/scripts/ci-sweep-selftest.sh; do
  expect_mutation_red "$real" "-m 1g" "-m/--memory"
  expect_mutation_red "$real" "--cpus 1" "--cpus"
done

if [ "$((PASSES + FAILURES))" -ne "$EXPECTED_ASSERTIONS" ] || [ "$FAILURES" -ne 0 ]; then
  printf '\n%s of %s assertions ran and %s failed. container-limits.sh has stopped discriminating.\n' \
    "$((PASSES + FAILURES))" "$EXPECTED_ASSERTIONS" "$FAILURES"
  exit 1
fi
printf '\nall %s assertions passed.\n' "$PASSES"
