#!/usr/bin/env bash
# Self-test for the CI checks.
#
# `images/` and `proxy/` hold nothing but a .gitkeep today, so a scan of the real
# tree finds no files and passes by being empty. A check that has never been
# observed printing anything is decoration. This script feeds every check input
# it must reject and input it must accept, and fails CI if a check stops
# discriminating. It keeps working after real files land: weaken a rule and the
# matching bad fixture goes quiet, which turns this red.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$REPO_ROOT/.github/ci-fixtures"
LIST="$REPO_ROOT/.github/scripts/list_compose.sh"
HADOLINT="${HADOLINT:-hadolint}"
FAILURES=0

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }
pass() { printf '  ok    %s\n' "$1"; }
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

section "hadolint"
expect_hadolint_clean "$FIXTURES/good/Dockerfile"
expect_hadolint_code "$FIXTURES/bad/Dockerfile" DL3007

section "compose discovery, by content and not by filename"
expect_listed "$FIXTURES/good" compose.yaml
expect_listed "$FIXTURES/good" stack.yaml
expect_not_listed "$FIXTURES/good" rollout.yml

if [ "${SKIP_COMPOSE_SELFTEST:-0}" != 1 ]; then
  section "compose validation"
  expect_compose_valid "$FIXTURES/good/compose.yaml"
  expect_compose_valid "$FIXTURES/good/stack.yaml"
  expect_compose_rejected "$FIXTURES/bad/schema.compose.yaml" ports
  expect_compose_rejected "$FIXTURES/bad/unparseable.compose.yml" yaml
fi

printf '\n'
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed. A check has stopped discriminating.\n' "$FAILURES"
  exit 1
fi
printf 'every check was observed passing on good input and failing on bad input\n'
