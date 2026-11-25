#!/usr/bin/env bash
# Self-test that RiftalDownstreamLimit lifts core's 5 s bad-packet block of a
# listed proxy address within a tick, and only then (riftal-infra#1470).
#
# Boots the real core image with the shipped plugin. fixture.php runs inside the
# container as a RakNet client: it completes the handshake, sends an 0xfe
# payload core rejects with a PacketHandlingException, then pings from the same
# source address, 127.0.0.1. Core logs "Blocked 127.0.0.1 for 5 seconds" and
# RakLib drops every datagram from that address, so the first pong comes back
# only when the block is lifted. Opted in, xbox-auth off and the address listed,
# the first ping at 1 s is answered. Three controls leave the pong silent until
# the block expires: no opt-in, xbox-auth on, an address list that does not hold
# 127.0.0.1. They also prove the test can see the block. Six mutants of the
# plugin must each turn the pong check red: handler emptied, unblock call
# removed, unblock deferred past 5 s, listed-address check inverted, opt-in gate
# dropped, xbox-auth gate dropped.
#
# Runs the pinned core image from ../../core-image.sha, present only on the
# self-hosted runners' Docker daemon. It publishes no port and keeps nothing:
# the data directory is the container's own anonymous volume, removed with it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$DIR/../RiftalDownstreamLimit.php"
. "$DIR/../../core-image.sh"
core_image || { printf 'the proxy address unblock was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"
ERRORS='CRITICAL|EMERGENCY|Exception|Stack trace'
# The fixture's first ping is at 1 s. A lifted block answers it. An unlifted
# one lasts 4 to 6 s, since RakLib expires it on a one second sweep.
QUICK_MS=2000
BLOCKED_MS=3500

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=42
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
name=""
cleanup() {
  if [ -n "$name" ]; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/fixture"
cp "$DIR/fixture.php" "$work/fixture/"

# $1 plugins directory name, $2 the RiftalDownstreamLimit.php to load
stack() {
  mkdir -p "$work/$1"
  cp "$2" "$work/$1/RiftalDownstreamLimit.php"
}
stack shipped "$PLUGIN"

# $1 plugins directory name, $2 the text of the plugin to replace, $3 what
# replaces it
mutant() {
  grep -qF "$2" "$PLUGIN" \
    || { printf '::error::RiftalDownstreamLimit.php no longer holds the text the %s control replaces\n' "$1"; exit 1; }
  while IFS= read -r line; do
    printf '%s\n' "${line//"$2"/"$3"}"
  done <"$PLUGIN" >"$work/$1.php"
  cmp -s "$work/$1.php" "$PLUGIN" \
    && { printf '::error::the %s control did not change RiftalDownstreamLimit.php\n' "$1"; exit 1; }
  stack "$1" "$work/$1.php"
}
mutant empty-handler '$this->unblockEvery($event->getInterface(), $proxies)' null
mutant no-unblock-call '$interface->unblockAddress($address);' ''
mutant deferred 'public const UNBLOCK_INTERVAL_TICKS = 1;' 'public const UNBLOCK_INTERVAL_TICKS = 200;'
mutant inverted-check 'filter_var($entry, FILTER_VALIDATE_IP) === false' 'filter_var($entry, FILTER_VALIDATE_IP) !== false'
mutant no-opt-in-gate '!$optedIn || ' ''
mutant no-auth-gate ' || $server->requiresAuthentication()' ''
chmod -R a+rX "$work"

# $1 plugins directory name, $2 server options; leaves the server log in
# $work/log, the fixture's output in $fixture_out and the exit status in $status
boot() {
  local run="$work/run" pid
  rm -rf "$run"
  mkdir -p "$run"
  mkfifo "$run/stdin"
  name="riftal_selftest_proxy_unblock_$$_$RANDOM"
  docker run --rm -i --name "$name" -m 2g --cpus 2 \
      -v "$work/$1:/plugins:ro" -v "$work/fixture:/fixture:ro" \
      -e "POCKETMINE_ARGS=$2 --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" <"$run/stdin" >"$work/log" 2>&1 &
  pid=$!
  exec 3>"$run/stdin"
  fixture_out="the server never reached Done"
  for _ in $(seq 1 400); do
    grep -qF 'Done (' "$work/log" && { fixture_out="$(docker exec "$name" php /fixture/fixture.php 127.0.0.1 19132 2>&1 || true)"; break; }
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo stop >&3 || true
    for _ in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  fi
  exec 3>&-
  if kill -0 "$pid" 2>/dev/null; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  status=0
  wait "$pid" || status=$?
  name=""
  grep -E 'Blocked|proxy address|downstream' "$work/log" || tail -n 20 "$work/log"
  printf 'fixture: %s\nexit status %s\n' "$fixture_out" "$status"
}

# The fixture's bad payload makes core log the PacketDecodeException it
# rejects it with, from its CRITICAL line to the end of the trace. That one is
# the stimulus; anything else matching ERRORS is an error.
unexpected() {
  awk '
    /\[Server thread\/CRITICAL\]: pocketmine\\network\\mcpe\\protocol\\PacketDecodeException/ { skip = 1 }
    !skip { print }
    /^--- End of exception information ---/ { skip = 0 }
  ' "$work/log" | grep -E "$ERRORS" || true
}

clean() {
  [ -z "$(unexpected)" ] && pass "$1: the server log has no error" \
    || fail "$1: the server log has an error: $(unexpected)"
}

# The milliseconds after the bad payload at which the first pong came back,
# nothing when none did.
pong_ms() {
  sed -n 's/^pong \([0-9]*\)$/\1/p' <<<"$fixture_out"
}

quick_pong() {
  local ms
  ms="$(pong_ms)"
  [ -n "$ms" ] && [ "$ms" -le "$QUICK_MS" ]
}

silent_pong() {
  local ms
  ms="$(pong_ms)"
  [ -z "$ms" ] || [ "$ms" -ge "$BLOCKED_MS" ]
}

handshook() {
  grep -q '^handshake ok' <<<"$fixture_out" \
    && pass "$1: the fixture completed the RakNet handshake" \
    || fail "$1: the fixture never completed the handshake: $fixture_out"
}

blocked() {
  grep -qF 'Blocked 127.0.0.1 for 5 seconds' "$work/log" \
    && pass "$1: core blocked 127.0.0.1 for 5 seconds" \
    || fail "$1: the log never shows 127.0.0.1 blocked for 5 seconds"
}

stopped() {
  [ "$status" -eq 0 ] && pass "$1: the server stops cleanly" \
    || fail "$1: the server exited $status"
}

PROXY='--riftal-downstream-proxies=127.0.0.1'
OPT_IN='--riftal-downstream=on'
OPEN="$OPT_IN --xbox-auth=false $PROXY"

printf '\n== opted in, xbox-auth off, 127.0.0.1 listed: the pong is answered\n'
boot shipped "$OPEN"
case_name="opted in"
clean "$case_name"
handshook "$case_name"
blocked "$case_name"
quick_pong && pass "$case_name: the pong came back $(pong_ms) ms after the bad payload" \
  || fail "$case_name: no pong within $QUICK_MS ms: $fixture_out"
grep -qF 'proxy address 127.0.0.1 unblocked every 1 tick on interface' "$work/log" \
  && pass "$case_name: the plugin logs the address it unblocks" \
  || fail "$case_name: the plugin never logged the address it unblocks"
stopped "$case_name"

# $1 case, $2 server options, $3 log line the plugin writes
control() {
  printf '\n== control: %s leaves the pong silent\n' "$1"
  boot shipped "$2"
  clean "$1"
  handshook "$1"
  blocked "$1"
  silent_pong && pass "$1: no pong for at least $BLOCKED_MS ms (first pong: ${fixture_out##*$'\n'})" \
    || fail "$1: a pong came back $(pong_ms) ms after the bad payload"
  grep -qF "$3" "$work/log" && pass "$1: the plugin logs: $3" \
    || fail "$1: the plugin never logged: $3"
  stopped "$1"
}
control "no opt-in" "--xbox-auth=false $PROXY" "proxy address unblock not started: riftal-downstream is not set"
control "xbox-auth on" "$OPT_IN --xbox-auth=true $PROXY" "proxy address unblock not started: xbox-auth is on"
control "an address that is not listed" "$OPT_IN --xbox-auth=false --riftal-downstream-proxies=10.255.255.1" "proxy address 10.255.255.1 unblocked every 1 tick on interface"

# $1 plugins directory name, $2 what the plugin does wrong, $3 server options
mutated() {
  printf '\n== control: a plugin %s fails %s\n' "$2" "$4"
  boot "$1" "$3"
  clean "control ($2)"
  blocked "control ($2)"
  ! "$4" && pass "control ($2): $4 rejects the log (first pong: ${fixture_out##*$'\n'})" \
    || fail "control ($2): $4 passed the log (first pong: ${fixture_out##*$'\n'})"
}
mutated empty-handler "whose handler does nothing" "$OPEN" quick_pong
mutated no-unblock-call "that never calls unblockAddress" "$OPEN" quick_pong
mutated deferred "that unblocks only after 200 ticks" "$OPEN" quick_pong
mutated inverted-check "that rejects the listed address" "$OPEN" quick_pong
mutated no-opt-in-gate "that ignores the opt-in" "--xbox-auth=false $PROXY" silent_pong
mutated no-auth-gate "that ignores xbox-auth" "$OPT_IN --xbox-auth=true $PROXY" silent_pong

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
printf 'all %s assertions passed: a listed proxy address is unblocked within a tick, and nothing else is.\n' "$PASSES"
