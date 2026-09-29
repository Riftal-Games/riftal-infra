#!/usr/bin/env bash
# Self-test for check-start-sh.sh (riftal-infra#272). Runs the check against
# the real record and image, then against a record whose hash is wrong, a
# record with no commit line, and an image that does not exist, and expects
# each of those to fail with an error naming what is wrong.
#
# Needs the local-pocketmine-mp image, present on the self-hosted runners.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-start-sh.sh"
RECORD="$DIR/start-sh.sha256"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=4
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
recorded="$(sed -n 's/^sha256 //p' "$RECORD")"

# Runs the check with the environment assignments in $@; its output lands in
# $work/out and its exit status is returned.
run() { env "$@" bash "$CHECK" > "$work/out" 2>&1; }
said() { grep -qF -- "$1" "$work/out"; }

printf '\n== the recorded hash matches the image\n'
check "the check passes on the real record and image" 'run'
cat "$work/out"

printf '\n== a record whose hash is not the image'"'"'s fails, naming both hashes\n'
wrong="$(printf '%s' "$recorded" | tr 0-9a-f 1-9a-f0)"
sed "s/^sha256 .*/sha256 $wrong/" "$RECORD" > "$work/wrong.sha256"
check "a mismatched hash fails and says to re-check start-instance.sh" \
  '! run START_SH_RECORD="$work/wrong.sha256" && said "::error::" &&
    said "$recorded" && said "records $wrong" && said "Re-check start-instance.sh"'
cat "$work/out"

printf '\n== a record without its pmmp-core commit fails\n'
grep -v '^pmmp-core ' "$RECORD" > "$work/nocommit.sha256"
check "a record with no pmmp-core line fails" \
  '! run START_SH_RECORD="$work/nocommit.sha256" && said "::error::" && said "pmmp-core <40 hex>"'
cat "$work/out"

printf '\n== a missing image fails and is never pulled\n'
absent="riftal_smoke_absent_$$_$RANDOM"
check "an absent image fails, naming it, and is still absent afterwards" \
  '! run START_SH_IMAGE="$absent" && said "::error::image $absent is not present" &&
    ! docker image inspect "$absent" >/dev/null 2>&1'
cat "$work/out"

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
printf 'all %s assertions passed\n' "$PASSES"
