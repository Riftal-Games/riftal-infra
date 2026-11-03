#!/usr/bin/env bash
# Self-test that RiftalDownstreamLimit turns RakLib's per-address packet limit
# off on every RakLib interface of an instance configured as a downstream, and
# on no other (riftal-infra#1376).
#
# Boots the real core image with the shipped plugin and the PacketLimitProbe of
# ../packet-limit beside it. The probe wraps the sender inside each RakLib
# interface and logs every setPacketsPerTickLimit value on its way to the RakLib
# thread, where the limit cannot be read back. Four cases: opted in with
# xbox-auth off sets PHP_INT_MAX on every interface, including one announced
# again later; no opt-in makes no call; the opt-in with xbox-auth on makes no
# call; with RiftalDevBots admitted beside it, the last value on every
# interface is PHP_INT_MAX, whichever handler ran first, because the plugin
# calls a tick after the event. Six controls mutate the plugin and the check
# for the case they break must then reject the log: handler emptied, call
# removed, value 200, call removed beside RiftalDevBots, opt-in gate dropped,
# xbox-auth gate dropped.
#
# Runs the pinned core image from ../../core-image.sha, present only on the
# self-hosted runners' Docker daemon. It publishes no port and keeps nothing:
# the data directory is the container's own anonymous volume, removed with it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$DIR/../RiftalDownstreamLimit.php"
. "$DIR/../../core-image.sh"
core_image || { printf 'the downstream packet limit was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"
ERRORS='CRITICAL|EMERGENCY|Exception|Stack trace'
MAX=9223372036854775807
DEV_BOTS_LIMIT=20000
HANDLER='$this->disableLater($event->getInterface())'
SET_CALL='$interface->setPacketLimit(self::PACKET_LIMIT);'

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=31
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 plugins directory name, $2 the RiftalDownstreamLimit.php to load, $3 "dev"
# to load RiftalDevBots beside it
stack() {
  mkdir -p "$work/$1"
  cp "$2" "$work/$1/RiftalDownstreamLimit.php"
  cp "$DIR/../packet-limit/PacketLimitProbe.php" "$work/$1/"
  [ "${3:-}" = dev ] && cp "$DIR/../RiftalDevBots.php" "$work/$1/"
  chmod -R a+rX "$work/$1"
}
stack shipped "$PLUGIN"
stack shipped-dev "$PLUGIN" dev

# $1 plugins directory name, $2 the text of the plugin to replace, $3 what
# replaces it, $4 "dev" to load RiftalDevBots beside it
mutant() {
  grep -qF "$2" "$PLUGIN" \
    || { printf '::error::RiftalDownstreamLimit.php no longer holds the text the %s control replaces\n' "$1"; exit 1; }
  while IFS= read -r line; do
    printf '%s\n' "${line//"$2"/"$3"}"
  done <"$PLUGIN" >"$work/$1.php"
  cmp -s "$work/$1.php" "$PLUGIN" \
    && { printf '::error::the %s control did not change RiftalDownstreamLimit.php\n' "$1"; exit 1; }
  stack "$1" "$work/$1.php" "${4:-}"
}
mutant empty-handler "$HANDLER" null
mutant no-set-call "$SET_CALL" ''
mutant other-value "$SET_CALL" '$interface->setPacketLimit(200);'
mutant no-set-call-dev "$SET_CALL" '' dev
mutant no-opt-in-gate '!$optedIn || ' ''
mutant no-auth-gate ' || $server->requiresAuthentication()' ''

# $1 plugins directory name, $2 server options, $3 RIFTAL_DEV_ENV value ("" for
# unset); leaves the log in $work/log and the exit status in $status
boot() {
  local name="riftal_selftest_downstream_limit_$$_$RANDOM"
  local env=()
  [ -n "${3:-}" ] && env=(-e "RIFTAL_DEV_ENV=$3")
  status=0
  timeout 180 docker run --rm --name "$name" -m 2g --cpus 2 \
      -v "$work/$1:/plugins:ro" "${env[@]}" \
      -e "POCKETMINE_ARGS=$2 --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" >"$work/log" 2>&1 || status=$?
  if [ "$status" -eq 124 ]; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  grep -E 'packet-limit-probe|packet limit' "$work/log" || tail -n 20 "$work/log"
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

# $1 interface id; prints every value the probe saw set on it, in order
values() {
  grep -E "setPacketsPerTickLimit\([0-9]+\) on interface $1([^0-9]|\$)" "$work/log" \
    | sed 's/.*setPacketsPerTickLimit(\([0-9]*\)).*/\1/' || true
}

observed() {
  grep -c 'packet-limit-probe observed' "$work/log" || true
}

# Holds when every id has PHP_INT_MAX observed before the announcement and the
# first id has it again after.
max_everywhere() {
  local announced first id
  announced="$(grep -nF 'packet-limit-probe registration announced' "$work/log" | head -n 1 | cut -d: -f1)"
  first="$(ids | head -n 1)"
  [ -n "$announced" ] && [ -n "$first" ] || return 1
  for id in $(ids); do
    grep -nE "setPacketsPerTickLimit\($MAX\) on interface $id([^0-9]|\$)" "$work/log" | cut -d: -f1 \
      | awk -v a="$announced" '$1 < a { found = 1 } END { exit !found }' || return 1
  done
  grep -nE "setPacketsPerTickLimit\($MAX\) on interface $first([^0-9]|\$)" "$work/log" | cut -d: -f1 \
    | awk -v a="$announced" '$1 > a { found = 1 } END { exit !found }'
}

no_call() {
  [ "$(observed)" -eq 0 ]
}

# Holds when RiftalDevBots set its limit on every interface and the last value
# set on each is PHP_INT_MAX.
max_last() {
  local id
  [ -n "$(ids)" ] || return 1
  for id in $(ids); do
    [ "$(values "$id" | head -n 1)" = "$DEV_BOTS_LIMIT" ] && [ "$(values "$id" | tail -n 1)" = "$MAX" ] || return 1
  done
}

found_ids() {
  [ -n "$(ids)" ] \
    && pass "$1: the probe found a RakLib interface to check" \
    || fail "$1: the probe found no RakLib interface, so nothing here was checked"
}

stopped() {
  [ "$status" -eq 0 ] && pass "$1: the server stops cleanly" \
    || fail "$1: the server exited $status"
}

# $1 case, $2 stack, $3 server options, $4 RIFTAL_DEV_ENV, $5 check function,
# $6 log line the plugin writes
case_holds() {
  printf '\n== %s\n' "$1"
  boot "$2" "$3" "$4"
  clean "$1"
  found_ids "$1"
  "$5" && pass "$1: $5 holds ($(observed) observed limits)" \
    || fail "$1: $5 does not hold: $(grep -E 'packet-limit-probe observed' "$work/log" || true)"
  grep -qF "$6" "$work/log" && pass "$1: the plugin logs: $6" \
    || fail "$1: the plugin never logged: $6"
  stopped "$1"
}

OPT_IN='--riftal-downstream=on'
case_holds "opted in, xbox-auth off: PHP_INT_MAX on every interface" shipped "$OPT_IN --xbox-auth=false" "" max_everywhere "downstream packet limit off on interface"
case_holds "no opt-in: no call" shipped "--xbox-auth=false" "" no_call "downstream packet limit not raised: riftal-downstream is not set"
case_holds "opted in, xbox-auth on: no call" shipped "$OPT_IN --xbox-auth=true" "" no_call "downstream packet limit not raised: xbox-auth is on"

printf '\n== with RiftalDevBots admitted: the last value is PHP_INT_MAX\n'
boot shipped-dev "$OPT_IN --xbox-auth=false --riftal-dev-bots=on" 1
clean "both plugins"
found_ids "both plugins"
max_last && pass "both plugins: RiftalDevBots set $DEV_BOTS_LIMIT and the last value on each interface is $MAX" \
  || fail "both plugins: the values on an interface do not end at $MAX: $(grep -E 'packet-limit-probe observed' "$work/log" || true)"
stopped "both plugins"

# $1 plugins directory name, $2 what the plugin does wrong, $3 server options,
# $4 RIFTAL_DEV_ENV, $5 the check that must reject its log
control() {
  printf '\n== control: a plugin %s fails %s\n' "$2" "$5"
  boot "$1" "$3" "$4"
  clean "control ($2)"
  ! "$5" \
    && pass "control ($2): $5 rejects the log ($(observed) observed limits)" \
    || fail "control ($2): $5 passed the log"
}
control empty-handler "whose handler sets nothing" "$OPT_IN --xbox-auth=false" "" max_everywhere
control no-set-call "that never calls setPacketLimit" "$OPT_IN --xbox-auth=false" "" max_everywhere
control other-value "that sets another limit" "$OPT_IN --xbox-auth=false" "" max_everywhere
control no-set-call-dev "that never calls setPacketLimit beside RiftalDevBots" "$OPT_IN --xbox-auth=false --riftal-dev-bots=on" 1 max_last
control no-opt-in-gate "that ignores the opt-in" "--xbox-auth=false" "" no_call
control no-auth-gate "that ignores xbox-auth" "$OPT_IN --xbox-auth=true" "" no_call

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
printf 'all %s assertions passed: the packet limit is off only on an opted-in downstream with xbox-auth off.\n' "$PASSES"
