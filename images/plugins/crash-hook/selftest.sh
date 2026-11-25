#!/usr/bin/env bash
# Self-test for RiftalDevBots' devbots-crash command (riftal-infra#594, ADR 017
# unit 6).
#
# Boots the real core image with the shipped RiftalDevBots.php and
# CrashHookProbe.php beside it. The probe runs the command as an operator, as
# a holder of the console permission that is not the console, and then as the
# console. With dev bots admitted, the operator and the holder are refused and
# the console kills the process: the probe never logs past it, and tini reports
# the server's SIGKILL as exit 137. Without the --riftal-dev-bots=on flag, or
# without RIFTAL_DEV_ENV=1, the command does not exist and the server shuts
# down cleanly. With the server as process 1, as in an image without tini,
# the kernel would drop the SIGKILL, so the command refuses and kills nothing.
#
# Runs the pinned core image from ../../core-image.sha, present only on the
# self-hosted runners' Docker daemon. It publishes no port and keeps nothing:
# /data is the container's own anonymous volume, removed with it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../core-image.sh"
core_image || { printf 'the crash hook was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"
ERRORS='/(EMERGENCY|ALERT|CRITICAL|ERROR)]|Exception|Stack trace'

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=15
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
plugins="$work/plugins"
mkdir -p "$plugins"
cp "$DIR/../RiftalDevBots.php" "$DIR/CrashHookProbe.php" "$plugins/"
chmod -R a+rX "$plugins"

# $1 --riftal-dev-bots value, $2 RIFTAL_DEV_ENV value ("" for unset),
# $3 "pid1" to bypass tini so the server is process 1; leaves the log in $work/log and the exit status in $status
boot() {
  local name="riftal_selftest_crash_hook_$$_$RANDOM"
  local env=()
  [ -n "$2" ] && env=(-e "RIFTAL_DEV_ENV=$2")
  local entry=()
  [ "${3:-}" = pid1 ] && entry=(--entrypoint start-pocketmine)
  status=0
  timeout 180 docker run --rm --name "$name" -m 2g --cpus 2 \
      -v "$plugins:/plugins:ro" "${env[@]}" "${entry[@]}" \
      -e "POCKETMINE_ARGS=--xbox-auth=false --riftal-dev-bots=$1 --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" >"$work/log" 2>&1 || status=$?
  if [ "$status" -eq 124 ]; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  grep -E 'crash-hook-probe|devbots-crash' "$work/log" || tail -n 20 "$work/log"
  printf 'exit status %s\n' "$status"
}

# $1 label, $2 optional fixed text of the one expected error line, dropped before the check
clean() {
  local found
  found="$(grep -E "$ERRORS" "$work/log" || true)"
  if [ -n "${2:-}" ]; then
    found="$(grep -vF -- "$2" <<<"$found" || true)"
  fi
  [ -z "$found" ] && pass "$1: the server log has no error" \
    || fail "$1: the server log has an error: $found"
}

printf '\n== dev bots admitted: the console kills the process, no other sender can\n'
boot on 1
clean "admitted"
grep -q 'crash-hook-probe registered=yes' "$work/log" \
  && pass "devbots-crash is registered" \
  || fail "devbots-crash is not registered with dev bots admitted"
grep -q 'crash-hook-probe alive after operator' "$work/log" \
  && grep -q "crash-hook-probe operator heard: You don't have permission" "$work/log" \
  && pass "an operator is refused and the process keeps running" \
  || fail "the operator's run was not refused, or killed the process"
grep -q 'crash-hook-probe alive after holder' "$work/log" \
  && grep -q "crash-hook-probe holder heard: devbots-crash runs only from the server console" "$work/log" \
  && pass "a console-permission holder that is not the console is refused and the process keeps running" \
  || fail "the holder's run was not refused by the console-only check, or killed the process"
grep -q 'devbots-crash: killing process' "$work/log" \
  && ! grep -qE 'crash-hook-probe alive after console|Stopping' "$work/log" \
  && pass "the console's run kills the process before any shutdown" \
  || fail "the console's run did not kill the process before a shutdown"
[ "$status" -eq 137 ] && pass "the server exits by SIGKILL (137)" \
  || fail "expected exit 137 from SIGKILL, got $status"

printf '\n== dev bots admitted, server is process 1: the console run refuses\n'
boot on 1 pid1
clean "process 1" "devbots-crash: refused, this server is process 1"
grep -q 'devbots-crash: refused, this server is process 1' "$work/log" \
  && pass "process 1: the console's run is refused, naming why" \
  || fail "process 1: the console's run was not refused as process 1"
grep -q 'crash-hook-probe alive after console' "$work/log" \
  && ! grep -q 'devbots-crash: killing process' "$work/log" \
  && [ "$status" -eq 0 ] \
  && pass "process 1: no kill is claimed and the server stops cleanly" \
  || fail "process 1: a kill was claimed, or the server did not stop cleanly (exit $status)"

# $1 --riftal-dev-bots value, $2 RIFTAL_DEV_ENV value, $3 description
absent() {
  printf '\n== %s: devbots-crash does not exist\n' "$3"
  boot "$1" "$2"
  grep -q 'crash-hook-probe registered=no' "$work/log" \
    && pass "$3: devbots-crash is not registered" \
    || fail "$3: devbots-crash is registered"
  grep -q 'crash-hook-probe alive after console' "$work/log" \
    && ! grep -q 'devbots-crash: killing process' "$work/log" \
    && [ "$status" -eq 0 ] \
    && pass "$3: the console's run kills nothing and the server stops cleanly" \
    || fail "$3: the server did not survive the console's run and stop cleanly (exit $status)"
  clean "$3"
}
absent off 1 "the dev-bots flag off"
absent on "" "RIFTAL_DEV_ENV unset"

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
printf 'all %s assertions passed: devbots-crash kills the server only from the console, and only with dev bots admitted.\n' "$PASSES"
