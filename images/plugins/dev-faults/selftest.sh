#!/usr/bin/env bash
# Self-test for RiftalDevFaults.php (riftal-infra#932, #1124 and #1325), the
# hooks of ADR 017 P8, ADR 030 and ADR 034.
#
# Boots the pinned core image six times on one throwaway /data volume, with
# the shipped RiftalDevBots.php and RiftalDevFaults.php beside two fixtures:
# DevFaultsCustody.php, named RiftalCustody and enabled at STARTUP as custody
# is, and DevFaultsContracts.php, named RiftalContracts and holding the
# DurableChunkSaveEvent contract and the economy contracts devfaults-debit
# uses. The custody fixture records whether the probe path is a directory when
# it enables, arms every fault through the console commands, saves two players
# through core, writes the probe the way custody does, fires three durable
# chunk save events as lib does, and runs devfaults-debit against a stub
# listener that answers debited, rejected, not_applied and failed in turn.
#
# The third boot must clear the directory the first armed before RiftalCustody
# enables; the fourth runs a copy that clears it in onEnable and must not, so
# the order check is known to tell the two apart. The fifth leaves
# RiftalDevBots out, and core must refuse RiftalDevFaults. The sixth leaves
# RiftalContracts out, and the player and probe faults must still hold.
#
# Runs the pinned core image from ../../core-image.sha, present only on the
# self-hosted runners' Docker daemon. It publishes no port, and the volume is
# a riftal_smoke_ one removed on exit.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$DIR/../RiftalDevFaults.php"
. "$DIR/../../core-image.sh"
core_image || { printf 'the dev faults hook was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"

instance=selftest-dev-faults
uuid7='[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
debit="devfaults-debit request_id=($uuid7) account_id=7 amount_minor_units=250 instance_id=$instance"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=18
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
volume="riftal_smoke_dev_faults_$$_$RANDOM"
docker volume create "$volume" >/dev/null
trap 'rm -rf "$work"; docker volume rm "$volume" >/dev/null' EXIT

# $1 RiftalDevFaults.php to load, $2 RIFTAL_DEV_ENV, $3 FAULTS_ARM_PROBE,
# $4 a boot number that keeps each boot's player names its own, $5 "nobots"
# to leave RiftalDevBots out or "nocontracts" to leave RiftalContracts out.
# Keeps the log at $work/log-$4 and prints the fixture's result line, or the
# log tail when there is none.
boot() {
  local plugins="$work/plugins-$4" name="riftal_selftest_dev_faults_$$_$RANDOM" log
  mkdir -p "$plugins"
  [ "${5:-}" = nobots ] || cp "$DIR/../RiftalDevBots.php" "$plugins/"
  [ "${5:-}" = nocontracts ] || cp "$DIR/DevFaultsContracts.php" "$plugins/DevFaultsContracts.php"
  cp "$DIR/DevFaultsCustody.php" "$plugins/DevFaultsCustody.php"
  cp "$1" "$plugins/RiftalDevFaults.php"
  chmod -R a+rX "$plugins"
  if ! log="$(timeout 180 docker run --rm --pull never --name "$name" -m 2g --cpus 2 \
      -v "$plugins:/plugins:ro" -v "$volume:/data" \
      -e "RIFTAL_DEV_ENV=$2" -e "FAULTS_ARM_PROBE=$3" -e "FAULTS_BOOT=$4" -e "INSTANCE_ID=$instance" \
      -e "POCKETMINE_ARGS=--xbox-auth=false --riftal-dev-bots=on --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" 2>&1)"; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$log" > "$work/log-$4"
  if grep -qE '/(EMERGENCY|ALERT|CRITICAL|ERROR)]|Exception|Stack trace' <<<"$log"; then
    printf 'server log has an error:\n%s\n' "$(grep -E '/(EMERGENCY|ALERT|CRITICAL|ERROR)]|Exception|Stack trace' <<<"$log")"
    return
  fi
  grep -o 'dev-faults-probe .*' <<<"$log" || tail -n 20 <<<"$log"
}

# $1 what the boot shows, $2 the expected result, $3 the fixture's line
expect() {
  printf '%s\n' "$3"
  [ "$3" = "dev-faults-probe $2" ] && pass "$1" || fail "$1: expected '$2', got: $3"
}

# $1 a boot number; prints whichever of the two lines its log has first
first() { grep -oE 'cleared the custody probe failure|Enabling RiftalCustody' "$work/log-$1" | head -n 1; }
clear='cleared the custody probe failure'

printf '\n== gated: the named player is not saved, another is, the probe throws, one chunk save is cancelled\n'
expect "every fault holds on a dev-shaped boot" \
  "dir_at_enable=no commands=yes failing=unsaved other=saved probe=throws chunk=saved,cancelled,saved" "$(boot "$PLUGIN" 1 1 1)"
cancels="$(grep -c 'cancelled the durable save of chunk 0 0 in ' "$work/log-1" || true)"
[ "$cancels" = 1 ] && grep -q 'devfaults-chunk-save-fail: no level nosuchlevel is loaded' "$work/log-1" \
  && pass "the log has one chunk cancel, and arming a level not loaded is refused" \
  || fail "boot 1 should log one chunk cancel and refuse nosuchlevel, got $cancels cancel line(s)"

printf '\n== RIFTAL_DEV_ENV unset: no command, none of the three by name, no listener, nothing cleared\n'
expect "a production-shaped boot has no hook and leaves the directory alone" \
  "dir_at_enable=yes commands=no failing=saved other=saved probe=throws chunk=saved,saved,saved" "$(boot "$PLUGIN" "" 1 2)"
grep -q 'dev-faults-commands devfaults-flush-fail=no devfaults-probe-fail=no devfaults-chunk-save-fail=no devfaults-debit=no' "$work/log-2" \
  && pass "with the gate closed, no fault command exists, the chunk and debit ones included" \
  || fail "boot 2 should have no fault command, got: $(grep -o 'dev-faults-commands .*' "$work/log-2" || echo 'no command line')"
! grep -qE 'devfaults-debit request_id=|dev-faults-debit |devfaults-debit is not registered' "$work/log-2" \
  && pass "with the gate closed, the log shows no debit fired and no debit warning" \
  || fail "boot 2 should show no devfaults-debit line, got: $(grep -E 'devfaults-debit request_id=|dev-faults-debit |devfaults-debit is not registered' "$work/log-2")"

printf '\n== devfaults-debit: a refused line fires nothing, four runs log the fire line and each outcome in turn\n'
grep -q 'dev-faults-debit refused_fired=0 refused_says=yes events=4 reasons=rank_up,rank_up,rank_up,rank_up' "$work/log-1" \
  && pass "a non-console sender and every missing, extra, zero, negative or non-decimal argument fire nothing, then four runs fire rank_up" \
  || fail "boot 1 should refuse every bad line and fire four rank_up events, got: $(grep -o 'dev-faults-debit .*' "$work/log-1" || echo 'no debit line')"
grep -E "devfaults-debit request_id=" "$work/log-1" | sed -E 's/^.*INFO\]: //' || true
fired="$(grep -oE "$debit reason=rank_up\$" "$work/log-1" | grep -oE "$uuid7" || true)"
outcomes="$(grep -oE "$debit outcome=[a-z_]+\$" "$work/log-1" || true)"
answered="$(sed -E 's/.* outcome=//' <<<"$outcomes" | paste -sd' ')"
[ "$(wc -l <<<"$fired")" = 4 ] && [ "$answered" = 'debited rejected not_applied failed' ] \
  && [ "$fired" = "$(grep -oE "$uuid7" <<<"$outcomes")" ] \
  && pass "four fire lines with a lowercase UUIDv7, reason rank_up, and one outcome line each in turn on the same id" \
  || fail "boot 1 should log four fire lines and the outcomes debited rejected not_applied failed on the same ids, got ids '$fired' and outcomes '$answered'"
[ "$(sort -u <<<"$fired" | wc -l)" = 4 ] \
  && pass "every run mints a request id of its own" \
  || fail "boot 1 should mint four different request ids, got: $fired"

printf '\n== the shipped plugin clears the armed directory before custody enables\n'
expect "custody's boot probe finds the directory gone, and it can be armed again" \
  "dir_at_enable=no commands=yes failing=unsaved other=saved probe=throws chunk=saved,cancelled,saved" "$(boot "$PLUGIN" 1 1 3)"
[ "$(first 3)" = "$clear" ] && pass "the log clears the probe failure before Enabling RiftalCustody" \
  || fail "the clear must come before Enabling RiftalCustody, got first: $(first 3)"

printf '\n== clearing in onEnable instead, custody enables before the clear\n'
copy="$work/clear-on-enable.php"
call=$'^\t\t\\$this->clearProbeFailure\\(\\);$'
sed -E "/$call/d; s/^\tprotected function onEnable\(\) : void\{$/&\n\t\t\$this->clearProbeFailure();/" "$PLUGIN" > "$copy"
[ "$(grep -cE "$call" "$PLUGIN")" = 1 ] && [ "$(grep -A1 'function onEnable' "$copy" | grep -cE "$call")" = 1 ] \
  && [ "$(grep -cE "$call" "$copy")" = 1 ] && pass "the copy moves exactly the one clear call into onEnable" \
  || fail "could not find exactly one clearProbeFailure() call outside onEnable in $PLUGIN"
expect "the copy leaves the armed directory for custody's boot probe to hit" \
  "dir_at_enable=yes commands=yes failing=unsaved other=saved probe=writes chunk=saved,cancelled,saved" "$(boot "$copy" 1 0 4)"
[ "$(first 4)" = "Enabling RiftalCustody" ] && pass "the order check sees the copy clear after Enabling RiftalCustody" \
  || fail "the copy should clear after Enabling RiftalCustody, got first: $(first 4)"

printf '\n== without RiftalDevBots: core refuses RiftalDevFaults, so no hook runs\n'
boot "$PLUGIN" 1 1 5 nobots
grep -qE "/CRITICAL\]: .*RiftalDevFaults.*RiftalDevBots" "$work/log-5" \
  && ! grep -qE 'dev faults (on|off)|dev-faults-probe' "$work/log-5" \
  && pass "a boot without RiftalDevBots names the missing dependency and loads no hook" \
  || fail "a boot without RiftalDevBots should refuse RiftalDevFaults for the missing dependency"

printf '\n== without RiftalContracts: the player and probe faults hold, the chunk fault is absent\n'
expect "a boot without RiftalContracts keeps the other faults" \
  "dir_at_enable=no commands=yes failing=unsaved other=saved probe=throws chunk=absent" "$(boot "$PLUGIN" 1 1 6 nocontracts)"
grep -q 'RiftalContracts is not loaded, so devfaults-chunk-save-fail is not registered' "$work/log-6" \
  && pass "the log names the missing RiftalContracts" \
  || fail "a boot without RiftalContracts should say the chunk fault is not registered"
grep -q 'RiftalContracts is not loaded, so devfaults-debit is not registered' "$work/log-6" \
  && grep -q 'dev-faults-commands devfaults-flush-fail=yes devfaults-probe-fail=yes devfaults-chunk-save-fail=no devfaults-debit=no' "$work/log-6" \
  && pass "without RiftalContracts the log names the missing debit command and the other faults still register" \
  || fail "a boot without RiftalContracts should warn that devfaults-debit is not registered and keep the other commands"

printf '\n== the shipped plugin can only debit\n'
! grep -q 'CurrencyCreditRequestedEvent' "$PLUGIN" \
  && pass "RiftalDevFaults.php names no CurrencyCreditRequestedEvent" \
  || fail "RiftalDevFaults.php must never name CurrencyCreditRequestedEvent: $(grep -n 'CurrencyCreditRequestedEvent' "$PLUGIN")"

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
printf 'all %s assertions passed: one named player fails to save, the probe fails and one armed chunk save is cancelled, only on a dev-shaped boot, and the next boot clears the probe before custody enables.\n' "$PASSES"
