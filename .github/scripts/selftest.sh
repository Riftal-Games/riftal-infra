#!/usr/bin/env bash
# Self-test for the CI checks.
#
# A check never observed printing anything is decoration. Each rule below gets
# input it must reject and input it must accept, driven through scan.sh itself
# rather than a second copy of its hadolint and `docker compose` calls, and
# part of this file drives scan.sh with no root or prune argument at all, the
# exact way ci.yml invokes it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$REPO_ROOT/.github/ci-fixtures"
LIST="$REPO_ROOT/.github/scripts/list_compose.sh"
SCAN="$REPO_ROOT/.github/scripts/scan.sh"
export HADOLINT="${HADOLINT:-hadolint}"
FAILURES=0
PASSES=0
# Every assertion below must run. A harness that quietly runs fewer and still
# prints its closing line is the exact failure it exists to catch.
EXPECTED_ASSERTIONS=98

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

# Both of these run the fixture through scan.sh itself, root set to the
# fixture file, so hadolint or `docker compose config` is reached through the
# real check_dockerfiles/check_compose and the real loop, not a second copy
# of the call living only in this file. A file as root works: find(1) tests a
# file argument directly against the same predicates it would apply inside a
# directory.
expect_scan_ok() {
  local kind="$1" file="$2" out status
  out="$(bash "$SCAN" "$kind" "$file" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -qF "checking $file"; then
    pass "$(rel "$file") checks clean through scan.sh $kind"
  else
    fail "expected $(rel "$file") to check clean through scan.sh $kind, exit $status"
    printf '%s\n' "$out"
  fi
}

# The needle is the fixture's own defect. Reject-because-the-tool-is-missing
# is caught by the expect_scan_ok sites above, which go red in that case too.
expect_scan_bad() {
  local kind="$1" file="$2" needle="$3" out status
  out="$(bash "$SCAN" "$kind" "$file" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qi "$needle"; then
    pass "$(rel "$file") rejected through scan.sh $kind, naming $needle"
  else
    fail "expected $(rel "$file") to be rejected through scan.sh $kind naming $needle, exit $status"
    printf '%s\n' "$out"
  fi
}

# ci.yml calls scan.sh with a kind and nothing else: no root, no prune
# argument, both left to scan.sh's own defaults. Every assertion above passes
# an explicit root, so none of them would notice a broken default. This plants
# a file outside .github/ci-fixtures, runs scan.sh exactly the way ci.yml
# does, and checks both properties a wrong root or a wrong prune would break:
# the planted file is discovered, and the fixtures tree, which is bad enough
# to fail every check, is not.
PLANTED_DIR="$REPO_ROOT/.ci-realscan-planted"

expect_real_scan() {
  local kind="$1" fixture="$2" name out status
  name="$(basename "$fixture")"
  mkdir -p "$PLANTED_DIR"
  cp "$fixture" "$PLANTED_DIR/$name"
  out="$(cd "$REPO_ROOT" && bash "$SCAN" "$kind" 2>&1)"
  status=$?
  rm -rf "$PLANTED_DIR"
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -qF "checking ./.ci-realscan-planted/$name" \
    && ! printf '%s' "$out" | grep -q 'ci-fixtures'; then
    pass "the real $kind invocation finds a planted file and excludes ci-fixtures"
  else
    fail "expected the real $kind invocation (no root, no prune argument) to find the planted file and exclude ci-fixtures, exit $status"
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

CLEANUP="$REPO_ROOT/.github/scripts/container-cleanup.sh"

# The needle includes the line number, so a fixture rejected for some other
# line than its one defect does not count.
expect_cleanup() {
  local file="$1" needle="$2" out status
  out="$(bash "$CLEANUP" "$file" 2>&1)"
  status=$?
  if [ -z "$needle" ] && [ "$status" -eq 0 ]; then
    pass "$(rel "$file") passes container-cleanup.sh"
  elif [ -n "$needle" ] && [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF "$file:$needle"; then
    pass "$(rel "$file") rejected by container-cleanup.sh at $needle"
  else
    fail "expected container-cleanup.sh on $(rel "$file") to give '${needle:-a pass}', exit $status"
    printf '%s\n' "$out"
  fi
}

# find(1) lists a directory in no fixed order, so each file opens with a run
# under the other's closing opt-out, and whichever is read second shows
# whether an opt-out carries into the next file.
expect_cleanup_carry() {
  local dir="$FIXTURES/bad/cleanup-optout-carry" out status
  out="$(bash "$CLEANUP" "$dir" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -qF "$dir/a.sh:1: a container started without --rm" \
    && printf '%s' "$out" | grep -qF "$dir/b.sh:1: a container started without --rm" \
    && printf '%s' "$out" | grep -qF "$dir/a.sh:2: a container-cleanup opt-out with no container" \
    && printf '%s' "$out" | grep -qF "$dir/b.sh:2: a container-cleanup opt-out with no container"; then
    pass "$(rel "$dir") keeps no opt-out across a file boundary"
  else
    fail "expected container-cleanup.sh on $(rel "$dir") to name both files' run and opt-out, exit $status"
    printf '%s\n' "$out"
  fi
}

# Each file ends on a continued run, so one is read before the other file
# starts and the other before the input ends, in whichever order find(1) gives.
expect_cleanup_eof_continued() {
  local dir="$FIXTURES/bad/cleanup-eof-continued" out status
  out="$(bash "$CLEANUP" "$dir" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -qF "$dir/a.sh:4: a container started without --rm" \
    && printf '%s' "$out" | grep -qF "$dir/b.sh:4: a container started without --rm"; then
    pass "$(rel "$dir") checks a run still continued when its file ends"
  else
    fail "expected container-cleanup.sh on $(rel "$dir") to name the continued run in both files, exit $status"
    printf '%s\n' "$out"
  fi
}

expect_real_cleanup() {
  local out status
  mkdir -p "$PLANTED_DIR"
  cp "$FIXTURES/bad/cleanup-rm.sh" "$PLANTED_DIR/cleanup-rm.sh"
  out="$(cd "$REPO_ROOT" && bash "$CLEANUP" 2>&1)"
  status=$?
  rm -rf "$PLANTED_DIR"
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -qF './.ci-realscan-planted/cleanup-rm.sh:5:' \
    && ! printf '%s' "$out" | grep -q 'ci-fixtures'; then
    pass "the real container-cleanup.sh invocation finds a planted file and excludes ci-fixtures"
  else
    fail "expected the real container-cleanup.sh invocation to flag the planted file and skip ci-fixtures, exit $status"
    printf '%s\n' "$out"
  fi
}

section "container cleanup takes the anonymous volumes with every container"
expect_cleanup "$FIXTURES/good/cleanup.sh" ""
expect_cleanup "$FIXTURES/bad/cleanup-rm.sh" "5: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-run.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-create.sh" "4: a container created without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-container-create.sh" "4: a container created without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-dollar.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-dollar-quoted.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-dollar-twice.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-brace.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-brace-quoted.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-semicolon.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-and.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-or.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-pipe.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-background.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-nosep.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-eol.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-quoted-comment.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-argcount.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-reason.sh" "4: a container-cleanup line that is not keep <reason>"
expect_cleanup "$FIXTURES/bad/cleanup-optout-keepword.sh" "4: a container-cleanup line that is not keep <reason>"
expect_cleanup "$FIXTURES/bad/cleanup-optout-notkeep.sh" "4: a container-cleanup line that is not keep <reason>"
expect_cleanup "$FIXTURES/bad/cleanup-optout-nospace.sh" "4: a container-cleanup line that is not keep <reason>"
expect_cleanup "$FIXTURES/bad/cleanup-optout-eof.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-twice.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-comment.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-comment.sh" "6: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-command.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-command.sh" "6: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-sameline.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-sameline.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-two-commands.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-rm.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-rm.sh" "5: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-optout-after-rm.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-after-rm.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-inline.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-unspaced.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-continued-hash.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-tab.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-unspaced.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-rm.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-comment-paren.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-twice.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-continued.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-continued-comment.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-length.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-strip.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-single.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-escaped.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-blank.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-subshell.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-multiline.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-continued.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-heredoc.sh" "7: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-apostrophe.sh" "7: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-apostrophe-quoted.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-dquote-in-single.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-url.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-dquote.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-ansi.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-in-flag.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-comment-run.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-in-word.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-in-word.sh" "6: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-in-word.sh" "7: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-image-rm.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "6: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "7: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "8: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "9: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "10: a container created without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "11: a container started without --rm"
expect_cleanup_carry
expect_cleanup_eof_continued
expect_real_cleanup

section "hadolint, through scan.sh's own check_dockerfiles"
expect_scan_ok dockerfiles "$FIXTURES/good/Dockerfile"
expect_scan_bad dockerfiles "$FIXTURES/bad/Dockerfile" DL3007

section "hadolint reaches Containerfile, not only Dockerfile"
expect_scan_ok dockerfiles "$FIXTURES/good/Containerfile"
expect_scan_bad dockerfiles "$FIXTURES/bad/Containerfile" DL3007

section "compose discovery, by content and not by filename"
expect_listed "$FIXTURES/good" compose.yaml
expect_listed "$FIXTURES/good" stack.yaml
expect_not_listed "$FIXTURES/good" rollout.yml

section "compose validation, through scan.sh's own check_compose"
expect_scan_ok compose "$FIXTURES/good/compose.yaml"
expect_scan_ok compose "$FIXTURES/good/stack.yaml"
expect_scan_bad compose "$FIXTURES/bad/schema.compose.yaml" ports
expect_scan_bad compose "$FIXTURES/bad/unparseable.compose.yml" yaml

section "php lint, broken file at each position in a multi-file batch"
expect_php_lint_clean "$FIXTURES/good/php-plugins"
expect_php_lint_rejected "$FIXTURES/bad/php-plugins-first" a_broken.php z_valid.php
expect_php_lint_rejected "$FIXTURES/bad/php-plugins-middle" m_broken.php z_valid.php
expect_php_lint_rejected "$FIXTURES/bad/php-plugins-last" z_broken.php a_valid.php

section "a failed discovery fails the scan, it does not read as an empty tree"
expect_scan_fails dockerfiles "$REPO_ROOT/no-such-tree"
expect_scan_fails compose "$FIXTURES/good" "$REPO_ROOT/no-such-lister.sh"

section "the exact invocation ci.yml uses: a kind, no root, no prune argument"
expect_real_scan dockerfiles "$FIXTURES/bad/Dockerfile"
expect_real_scan compose "$FIXTURES/bad/schema.compose.yaml"

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
printf 'all %s assertions passed, both sides for hadolint, discovery, compose, php lint and container cleanup.\n' "$PASSES"
printf 'scan.sh itself is exercised end to end: discovery, both check functions, the loop, and the exact no-argument invocation ci.yml uses.\n'
