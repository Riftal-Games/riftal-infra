#!/usr/bin/env bash
# Self-test for core_image in core-image.sh (riftal-infra#363): the committed
# pin resolves to its exact tag, and every way of not having that tag fails
# with an ::error:: instead of a skip or a fallback to the bare tag.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/core-image.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=5
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pinned="$(tr -d '[:space:]' < "$DIR/core-image.sha")"
if core_image && [ "$CORE_IMAGE" = "local-pocketmine-mp:$pinned" ]; then
  pass "the committed pin resolves to local-pocketmine-mp:$pinned"
else
  fail "the committed pin did not resolve to local-pocketmine-mp:$pinned, got: ${CORE_IMAGE:-nothing}"
fi

# $1 what the case is, $2 the sha file's content or "" for no file, $3 text
# the ::error:: must contain
refused() {
  local file="$work/case-$PASSES-$FAILURES.sha" out
  if [ -n "$2" ]; then
    printf '%s\n' "$2" > "$file"
  fi
  if out="$(core_image "$file" 2>/dev/null)"; then
    fail "$1 was accepted"
  elif grep -qF "::error::" <<<"$out" && grep -qF "$3" <<<"$out"; then
    pass "$1 is refused: $out"
  else
    fail "$1 was refused without an ::error:: naming $3, got: $out"
  fi
}

refused "a sha whose tag is not on this daemon" \
  0000000000000000000000000000000000000000 \
  local-pocketmine-mp:0000000000000000000000000000000000000000
# The daemon refusal also names a short sha inside its tag, so only the
# length refusal's own wording tells the two apart.
refused "a short sha" "${pinned:0:9}" "\"${pinned:0:9}\", not a full 40-character"
refused "the bare latest tag" latest '"latest"'
refused "a missing sha file" "" "cannot read"

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed: checks run the pinned core image or fail.\n' "$PASSES"
