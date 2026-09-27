#!/usr/bin/env bash
# Self-test for the CI checks.
#
# `images/` and `proxy/` hold only a .gitkeep today, so a scan of the real tree
# passes by being empty, and a check never observed printing anything is
# decoration. Each rule below gets input it must reject and input it must accept,
# through this script's own hadolint and `docker compose` calls, not scan.sh's.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$REPO_ROOT/.github/ci-fixtures"
LIST="$REPO_ROOT/.github/scripts/list_compose.sh"
SCAN="$REPO_ROOT/.github/scripts/scan.sh"
HADOLINT="${HADOLINT:-hadolint}"
FAILURES=0
PASSES=0
# Every assertion below must run. A harness that quietly runs fewer and still
# prints its closing line is the exact failure it exists to catch.
EXPECTED_ASSERTIONS=15

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

expect_hadolint_clean() {
  local out status
  out="$("$HADOLINT" "$1" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "$(rel "$1") lints clean"
  else
    fail "expected $(rel "$1") to lint clean, hadolint exited $status"
    printf '%s\n' "$out"
  fi
}

# One code per fixture. An assertion that only wants a non-zero exit stays green
# when the defect it names is fixed and an unrelated one is introduced.
expect_hadolint_code() {
  local out status
  out="$("$HADOLINT" "$1" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -q "$2"; then
    pass "$(rel "$1") -> $2"
  else
    fail "expected $2 from $(rel "$1"), exit $status"
    printf '%s\n' "$out"
  fi
}

expect_compose_valid() {
  local out status
  out="$(docker compose -f "$1" config --quiet 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "$(rel "$1") validates"
  else
    fail "expected $(rel "$1") to validate, docker compose exited $status"
    printf '%s\n' "$out"
  fi
}

# The needle is the fixture's own defect. Reject-because-docker-is-missing is
# caught by the expect_compose_valid sites above, which go red in that case.
expect_compose_rejected() {
  local out status
  out="$(docker compose -f "$1" config --quiet 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qi "$2"; then
    pass "$(rel "$1") rejected, naming $2"
  else
    fail "expected $(rel "$1") to be rejected naming $2, exit $status"
    printf '%s\n' "$out"
  fi
}

# Discovery is a check in its own right. A compose file nothing looks at is
# validated by nothing and reported as success, which reads exactly like clean.
expect_listed() {
  local out
  out="$(bash "$LIST" "$1")"
  if printf '%s\n' "$out" | grep -q "/$2\$"; then
    pass "discovery lists $2"
  else
    fail "expected $2 in the compose list of $(rel "$1")"
    printf '%s\n' "$out"
  fi
}

expect_not_listed() {
  local out
  out="$(bash "$LIST" "$1")"
  if printf '%s\n' "$out" | grep -q "/$2\$"; then
    fail "$2 is not compose and must not be handed to docker compose"
    printf '%s\n' "$out"
  else
    pass "discovery skips $2"
  fi
}

# The same accumulator the real "Lint PHP plugins" step runs, against a fixture
# directory instead of images/plugins/. Three implementation rounds on
# ci.yml's PHP lint step each swallowed a real syntax error by way of a
# different shell/CLI exit-status quirk (a bare for-loop with no set -e, an
# -exec {} + batching misdiagnosis, and find -exec {} \; discarding a match's
# own exit status). This runs the exact prescribed pattern so a future edit
# back toward any of those shapes turns this red on the same commit.
run_php_lint_batch() {
  docker run --rm -v "$1:/plugins:ro" php:8.3-cli-alpine sh -c '
    status=0
    for f in /plugins/*.php; do
      php -l "$f" || status=1
    done
    exit "$status"
  '
}

expect_php_lint_clean() {
  local out status
  out="$(run_php_lint_batch "$1" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "$(rel "$1") lints clean"
  else
    fail "expected $(rel "$1") to lint clean, php -l batch exited $status"
    printf '%s\n' "$out"
  fi
}

# Two needles, not one: the broken file must be named as a failure, and a
# companion file elsewhere in the batch must still show its own clean result.
# A checker that stops at the first failure, or that only reports the last
# file it happened to run, passes the first needle and fails the second.
expect_php_lint_rejected() {
  local dir="$1" broken="$2" survivor="$3"
  local out status
  out="$(run_php_lint_batch "$dir" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -q "Errors parsing /plugins/$broken" \
    && printf '%s' "$out" | grep -q "No syntax errors detected in /plugins/$survivor"; then
    pass "$(rel "$dir") rejected at $broken, $survivor still checked"
  else
    fail "expected $(rel "$dir") to fail naming $broken with $survivor still checked, exit $status"
    printf '%s\n' "$out"
  fi
}

# A scan is only as good as its discovery. A discovery that dies must fail the
# scan: reported as an empty tree it goes green over files nothing looked at.
expect_scan_fails() {
  local out status
  out="$(LISTER="${3:-}" bash "$SCAN" "$1" "$2" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ]; then
    pass "scan $1 fails when discovery fails"
  else
    fail "expected scan $1 to fail when discovery fails, exit $status"
    printf '%s\n' "$out"
  fi
}

section "hadolint"
expect_hadolint_clean "$FIXTURES/good/Dockerfile"
expect_hadolint_code "$FIXTURES/bad/Dockerfile" DL3007

section "compose discovery, by content and not by filename"
expect_listed "$FIXTURES/good" compose.yaml
expect_listed "$FIXTURES/good" stack.yaml
expect_not_listed "$FIXTURES/good" rollout.yml

section "compose validation"
expect_compose_valid "$FIXTURES/good/compose.yaml"
expect_compose_valid "$FIXTURES/good/stack.yaml"
expect_compose_rejected "$FIXTURES/bad/schema.compose.yaml" ports
expect_compose_rejected "$FIXTURES/bad/unparseable.compose.yml" yaml

section "php lint, broken file at each position in a multi-file batch"
expect_php_lint_clean "$FIXTURES/good/php-plugins"
expect_php_lint_rejected "$FIXTURES/bad/php-plugins-first" a_broken.php z_valid.php
expect_php_lint_rejected "$FIXTURES/bad/php-plugins-middle" m_broken.php z_valid.php
expect_php_lint_rejected "$FIXTURES/bad/php-plugins-last" z_broken.php a_valid.php

section "a failed discovery fails the scan, it does not read as an empty tree"
expect_scan_fails dockerfiles "$REPO_ROOT/no-such-tree"
expect_scan_fails compose "$FIXTURES/good" "$REPO_ROOT/no-such-lister.sh"

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed. A check has stopped discriminating.\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed, both sides for hadolint, discovery, compose and php lint.\n' "$PASSES"
printf 'The scan is asserted failing only, its tool calls not at all: riftal-infra#23.\n'
