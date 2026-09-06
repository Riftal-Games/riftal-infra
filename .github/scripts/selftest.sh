#!/usr/bin/env bash
# Self-test for the CI checks.
#
# `images/` and `proxy/` hold nothing but a .gitkeep today, so a scan of the
# real tree finds no files and passes by being empty. A check that has never
# been observed printing anything is decoration. This script therefore feeds
# every check a fixture that must fail and a fixture that must pass, and fails
# CI if a check stops discriminating. It keeps working after real files land:
# if someone weakens a rule, the matching bad fixture goes quiet and this goes
# red.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$REPO_ROOT/.github/ci-fixtures"
CHECKER="$REPO_ROOT/.github/scripts/check_port_policy.py"
HADOLINT="${HADOLINT:-hadolint}"
FAILURES=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

section() { printf '\n== %s\n' "$1"; }

# expect_policy_clean <file>
expect_policy_clean() {
  local target="$1" out status
  out="$(python3 "$CHECKER" "$target" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "policy clean: ${target#"$REPO_ROOT"/}"
  else
    fail "expected ${target#"$REPO_ROOT"/} to be clean, checker exited $status"
    printf '%s\n' "$out"
  fi
}

# expect_policy_finding <file> <code>...
expect_policy_finding() {
  local target="$1"; shift
  local out status code
  out="$(python3 "$CHECKER" "$target" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    fail "expected ${target#"$REPO_ROOT"/} to fail the port policy, it passed"
    printf '%s\n' "$out"
    return
  fi
  for code in "$@"; do
    if printf '%s' "$out" | grep -q "$code"; then
      pass "${target#"$REPO_ROOT"/} -> $code"
    else
      fail "expected $code from ${target#"$REPO_ROOT"/}, did not get it"
      printf '%s\n' "$out"
    fi
  done
}

# expect_lists <compose|scripts> <root> <needle>
# Discovery is a check in its own right: a file nothing looks at passes with
# exit 0 and says nothing, which reads exactly like clean.
expect_lists() {
  local kind="$1" root="$2" needle="$3" out status
  out="$(python3 "$CHECKER" "$root" --list "$kind" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q "$needle"; then
    pass "walk lists $needle as $kind"
  else
    fail "expected $needle in the $kind list of ${root#"$REPO_ROOT"/}, exit $status"
    printf '%s\n' "$out"
  fi
}

# expect_cmd <expected-status: pass|fail> <label> <command...>
expect_cmd() {
  local want="$1" label="$2"; shift 2
  local out status
  out="$("$@" 2>&1)"
  status=$?
  if [ "$want" = pass ] && [ "$status" -eq 0 ]; then
    pass "$label"
  elif [ "$want" = fail ] && [ "$status" -ne 0 ]; then
    pass "$label (exited $status as required)"
  else
    fail "$label: wanted $want, got exit $status"
    printf '%s\n' "$out"
  fi
}

section "port policy, must stay clean"
expect_policy_clean "$FIXTURES/good/compose.yaml"
expect_policy_clean "$FIXTURES/good/run-proxy.sh"
# Ordinary shell is not a publish. If this goes red, the next person to hit it
# weakens the rule or excludes the file, and the gate dies quietly.
expect_policy_clean "$FIXTURES/good/ops.sh"

section "port policy, must stay red"
expect_policy_finding "$FIXTURES/bad/tcp-publish.compose.yaml" BEDROCK_TCP_PUBLISH
expect_policy_finding "$FIXTURES/bad/instance-published.compose.yaml" \
  HOST_PUBLISH_NOT_ALLOWED HOST_NETWORK_MODE
expect_policy_finding "$FIXTURES/bad/db-public.compose.yaml" LOOPBACK_BIND_REQUIRED
expect_policy_finding "$FIXTURES/bad/schema.compose.yaml" COMPOSE_SCHEMA
expect_policy_finding "$FIXTURES/bad/unparseable.compose.yaml" COMPOSE_UNPARSEABLE
expect_policy_finding "$FIXTURES/bad/run-instance.sh" \
  HOST_PUBLISH_NOT_ALLOWED BEDROCK_TCP_PUBLISH PUBLISH_ALL_NOT_ALLOWED
# The word proxy on the line buys nothing. Pair this with good/run-proxy.sh,
# which passes on its --name: the two point in opposite directions, so a rule
# that classified by the whole line again would flip exactly one of them.
expect_policy_finding "$FIXTURES/bad/run-downstream-proxy-net.sh" \
  HOST_PUBLISH_NOT_ALLOWED
expect_policy_finding "$FIXTURES/bad/run-attached-publish.sh" \
  BEDROCK_TCP_PUBLISH HOST_PUBLISH_NOT_ALLOWED
# A flag the parser cannot size must not hide the -p behind it. Guessing it
# boolean reads the flag's value as the image and ends the scan, so the whole
# command goes unseen and the checker exits 0 on an open downstream. Long and
# short are separate fixtures because they are separate tables, and the short
# one shipped unguarded while the long one was fixed.
expect_policy_finding "$FIXTURES/bad/run-unlisted-flag.sh" \
  HOST_PUBLISH_NOT_ALLOWED BEDROCK_TCP_PUBLISH
expect_policy_finding "$FIXTURES/bad/run-unlisted-short-flag.sh" \
  HOST_PUBLISH_NOT_ALLOWED BEDROCK_TCP_PUBLISH
# Seeing the publish is half of it. An uncertain parse must also refuse to read
# a permission tier out of the word it is uncertain about. The second string
# asserts which path produced the finding: swap that fixture's flag for one the
# tables size and the deny arrives from the image instead, which is a different
# rule passing for a different reason.
expect_policy_finding "$FIXTURES/bad/run-unsized-no-name.sh" \
  HOST_PUBLISH_NOT_ALLOWED "unidentified"
expect_policy_finding "$FIXTURES/bad/stack.yaml" \
  BEDROCK_TCP_PUBLISH HOST_PUBLISH_NOT_ALLOWED HOST_NETWORK_MODE

section "discovery, by content and not by filename"
expect_lists compose "$FIXTURES/bad" "stack.yaml"
expect_lists compose "$FIXTURES/good" "compose.yaml"
expect_lists scripts "$FIXTURES/good" "ops.sh"

section "hadolint"
expect_cmd pass "good Dockerfile lints clean" \
  "$HADOLINT" "$FIXTURES/good/Dockerfile"
expect_cmd fail "bad Dockerfile is rejected" \
  "$HADOLINT" "$FIXTURES/bad/Dockerfile"

if [ "${SKIP_COMPOSE_SELFTEST:-0}" != 1 ]; then
  section "compose validation"
  expect_cmd pass "good compose validates" \
    docker compose -f "$FIXTURES/good/compose.yaml" config --quiet
  expect_cmd fail "invalid compose schema is rejected" \
    docker compose -f "$FIXTURES/bad/schema.compose.yaml" config --quiet
  expect_cmd fail "unparseable compose is rejected" \
    docker compose -f "$FIXTURES/bad/unparseable.compose.yaml" config --quiet
fi

printf '\n'
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed. A check has stopped discriminating.\n' "$FAILURES"
  exit 1
fi
printf 'every check was observed passing on good input and failing on bad input\n'
