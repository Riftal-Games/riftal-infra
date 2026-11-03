#!/usr/bin/env bash
# Self-test that RiftalDevBots raises RakLib's per-address packet limit on
# every RakLib interface, and only while dev bots are admitted
# (riftal-infra#1375).
#
# RakLib counts datagrams per source address within one drain cycle and blocks
# the address for 300 s at the limit. Every bot on the bot-proofs network
# arrives from the one gateway address, so the default of 200 is shared by the
# whole fleet.
#
# Boots the real core image with the shipped RiftalDevBots.php and
# PacketLimitProbe.php beside it. Plugins enable before the network interfaces
# start, so the plugin reaches each one through the register event. The probe
# lists the RakLib interfaces by object id once the server ticks and then
# announces the first of them as a registration again. With dev bots admitted
# the log carries a limit line for every id before the announcement and another
# for the first id after it. Without the --riftal-dev-bots=on flag, or without
# RIFTAL_DEV_ENV=1, it carries none. The control empties the handler, and the
# check then rejects the log.
#
# The limit itself lives in the RakLib thread and cannot be read back from the
# plugin, so this holds that the call is made on each interface; the bot-proofs
# job holds the effect.
#
# Runs the pinned core image from ../../core-image.sha, present only on the
# self-hosted runners' Docker daemon. It publishes no port and keeps nothing:
# the data directory is the container's own anonymous volume, removed with it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../core-image.sh"
core_image || { printf 'the packet limit was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"
ERRORS='CRITICAL|EMERGENCY|Exception|Stack trace'
LIMIT='raklib packet limit 20000 on interface '
CALL='$this->raisePacketLimit($event->getInterface())'

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=14
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 plugins directory name, $2 the RiftalDevBots.php to load
stack() {
  mkdir -p "$work/$1"
  cp "$2" "$work/$1/RiftalDevBots.php"
  cp "$DIR/PacketLimitProbe.php" "$work/$1/"
  chmod -R a+rX "$work/$1"
}
stack shipped "$DIR/../RiftalDevBots.php"

grep -qF "$CALL" "$DIR/../RiftalDevBots.php" \
  || { printf '::error::RiftalDevBots.php no longer holds the call the control empties\n'; exit 1; }
while IFS= read -r line; do
  printf '%s\n' "${line//"$CALL"/null}"
done <"$DIR/../RiftalDevBots.php" >"$work/empty-handler.php"
cmp -s "$work/empty-handler.php" "$DIR/../RiftalDevBots.php" \
  && { printf '::error::the control did not change RiftalDevBots.php\n'; exit 1; }
stack empty-handler "$work/empty-handler.php"

# $1 plugins directory name, $2 --riftal-dev-bots value, $3 RIFTAL_DEV_ENV
# value ("" for unset); leaves the log in $work/log and the exit status in
# $status
boot() {
  local name="riftal_selftest_packet_limit_$$_$RANDOM"
  local env=()
  [ -n "$3" ] && env=(-e "RIFTAL_DEV_ENV=$3")
  status=0
  timeout 180 docker run --rm --name "$name" -m 2g --cpus 2 \
      -v "$work/$1:/plugins:ro" "${env[@]}" \
      -e "POCKETMINE_ARGS=--xbox-auth=false --riftal-dev-bots=$2 --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" >"$work/log" 2>&1 || status=$?
  if [ "$status" -eq 124 ]; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  grep -E 'packet-limit-probe|raklib packet limit' "$work/log" || tail -n 20 "$work/log"
  printf 'exit status %s\n' "$status"
}

clean() {
  ! grep -qE "$ERRORS" "$work/log" && pass "$1: the server log has no error" \
    || fail "$1: the server log has an error: $(grep -E "$ERRORS" "$work/log")"
}

# Prints the probe's RakLib interface ids, one per line, nothing when it
# never logged them.
ids() {
  sed -n 's/.*packet-limit-probe raklib=[0-9]* ids=\([0-9,]*\).*/\1/p' "$work/log" \
    | head -n 1 | tr ',' '\n' | grep . || true
}

limit_lines() {
  grep -cF "$LIMIT" "$work/log" || true
}

# Holds when every id has a limit line before the announcement and the first
# id has another after it.
admitted_shape() {
  local announced first id
  announced="$(grep -nF 'packet-limit-probe registration announced' "$work/log" | head -n 1 | cut -d: -f1)"
  [ -n "$announced" ] || return 1
  first="$(ids | head -n 1)"
  [ -n "$first" ] || return 1
  for id in $(ids); do
    grep -nF "${LIMIT}${id}" "$work/log" | cut -d: -f1 \
      | awk -v a="$announced" '$1 < a { found = 1 } END { exit !found }' || return 1
  done
  grep -nF "${LIMIT}${first}" "$work/log" | cut -d: -f1 \
    | awk -v a="$announced" '$1 > a { found = 1 } END { exit !found }'
}

printf '\n== dev bots admitted: every RakLib interface gets the limit\n'
boot shipped on 1
clean "admitted"
[ -n "$(ids)" ] \
  && pass "admitted: the probe found a RakLib interface to check" \
  || fail "admitted: the probe found no RakLib interface, so nothing here was checked"
admitted_shape \
  && pass "admitted: every interface id has a limit line before the registration and the first has one after it ($(limit_lines) lines)" \
  || fail "admitted: a limit line is missing for an interface id ($(ids | tr '\n' ' ')); the log has $(limit_lines) limit lines"
[ "$status" -eq 0 ] && pass "admitted: the server stops cleanly" \
  || fail "admitted: the server exited $status"

printf '\n== control: with an empty register handler the shape check fails\n'
boot empty-handler on 1
clean "control"
! admitted_shape \
  && pass "control: the shape check rejects a plugin whose handler raises nothing ($(limit_lines) limit lines)" \
  || fail "control: the shape check passed a plugin whose handler raises nothing"

# $1 --riftal-dev-bots value, $2 RIFTAL_DEV_ENV value, $3 description
absent() {
  printf '\n== %s: no limit is raised\n' "$3"
  boot shipped "$1" "$2"
  clean "$3"
  [ -n "$(ids)" ] \
    && pass "$3: the probe found a RakLib interface to check" \
    || fail "$3: the probe found no RakLib interface, so nothing here was checked"
  [ "$(limit_lines)" -eq 0 ] \
    && pass "$3: no limit line, including after the announced registration" \
    || fail "$3: the limit was raised: $(grep -F "$LIMIT" "$work/log")"
  [ "$status" -eq 0 ] && pass "$3: the server stops cleanly" \
    || fail "$3: the server exited $status"
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
printf 'all %s assertions passed: RakLib interfaces get the raised packet limit only while dev bots are admitted.\n' "$PASSES"
