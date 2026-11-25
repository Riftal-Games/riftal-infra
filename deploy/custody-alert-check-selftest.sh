#!/usr/bin/env bash
# Self-test for custody-alert-check.sh. Reads fixture logs only and starts no
# container. Every alert rule has a case that must alert and a case that must
# pass, so a check that alerts on everything fails here as surely as one that
# alerts on nothing. CUSTODY_CHECK names another copy of the script to test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${CUSTODY_CHECK:-$SCRIPT_DIR/custody-alert-check.sh}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

e='[Server thread/EMERGENCY]: [RiftalCustody]'
quiet() {
  printf '%s\n' \
    '[11:59:59.000] [Server thread/INFO]: Loading server configuration' \
    '[12:00:00.000] [Server thread/INFO]: Enabling RiftalCustody v0.1.0' \
    '[12:00:00.500] [Server thread/INFO]: Done (1.234s)! For help, type "help" or "?"' \
    '[12:00:01.000] [Server thread/EMERGENCY]: [OtherPlugin] not a custody line'
}
# riftal-game custody/src/RiftalGames/Custody/FlushFailureResponse.php:76
probe_failed="$e flushing Steve failed at file fsync and the probe failed too, so no player file can be made durable; killing the process"
# riftal-game custody/src/RiftalGames/Custody/Shutdown.php:32-33, the runtime-disable form
disabled="$e RiftalCustody was disabled while the server is running; killing the process so no world saves without it"
# riftal-game custody/src/RiftalGames/Custody/Shutdown.php:32-33, the refused-boot form
boot_refused="$e RiftalCustody refused to enable (the probe failed at startup (disk full)) while the server is running; killing the process so no world saves without it"
# riftal-game custody/src/RiftalGames/Custody/FlushFailureResponse.php:87, both branches of its probe clause
held() { printf '%s flushing %s failed at save and the probe held; destroyed 3 item-yielding entities in mine-a, plots-1 and refusing %s until restart\n' "$e" "$1" "$1"; }
nothing() { printf '%s flushing %s failed at read-back with nothing to probe; destroyed 0 item-yielding entities in  and refusing %s until restart\n' "$e" "$1" "$1"; }

log() {
  local name="$1"
  shift
  { quiet; printf '%s\n' "$@"; } >"$DIR/$name"
}
log quiet.log
log probe.log "$probe_failed"
log disabled.log "$disabled"
log boot-refused.log "$boot_refused"
log steve.log "$(held Steve)"
log steve-upper.log "$(nothing sTEVE)"
log alex.log "$(nothing Alex)"
log alex-twice.log "$(held Alex)" "$(held alex)"
log reworded.log "$e flushing Steve failed at save; the probe failed, killing the process"
log unprefixed.log '[12:00:02.000] [Server thread/EMERGENCY]: RiftalCustody was disabled while the server is running; killing the process so no world saves without it'
# A log copied off a Windows host ends its lines in CRLF.
{ quiet; printf '%s\r\n' "$probe_failed"; } >"$DIR/crlf.log"
# server.log as an instance leaves it: two lifetimes appended in one file.
cat "$DIR/probe.log" "$DIR/disabled.log" >"$DIR/merged.log"
# One lifetime archived by size while running: its head ends a log_archive
# file and its tail opens server.log after MainLoggerThread's archive notice.
log head.log
printf '%s\n' '--- Starting new log file - old log file archived as server.2026-10-10T12.00.00.0.log ---' \
  "$disabled" >"$DIR/tail.log"
cat "$DIR/head.log" "$DIR/tail.log" >"$DIR/joined.log"
# What PocketMine.php can log ahead of the oldest boot line.
printf '%s\n' '[11:59:58.000] [Server thread/WARNING]: Non-packaged installation detected. This will degrade autoloading speed and make startup times longer.' \
  >"$DIR/preboot.log"

failures=0
ran=0
expected=18
# check <exit> <regex some output line must match> <case> <log>...
check() {
  local want="$1" match="$2" case="$3" out got
  shift 3
  ran=$((ran + 1))
  set +e
  out="$(cd "$DIR" && bash "$CHECK" "$@" 2>&1)"
  got=$?
  set -e
  if [ "$got" -ne "$want" ] || ! grep -q -E -- "$match" <<<"$out" ||
    { [ "$want" -ne 1 ] && grep -q 'CUSTODY ALERT' <<<"$out"; }; then
    printf 'FAIL %s: want exit %s matching /%s/, got exit %s:\n%s\n' "$case" "$want" "$match" "$got" "$out"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$case"
  fi
}

check 0 '^CUSTODY OK: 3 log\(s\), 1 instance-wide' 'one instance-wide stop passes' \
  quiet.log crlf.log quiet.log
check 1 '^CUSTODY ALERT: instance-wide custody stop in two consecutive logs: probe.log:5, then disabled.log:5$' \
  'two consecutive instance-wide stops alert' probe.log disabled.log
check 0 '^CUSTODY OK: 3 log\(s\), 2 instance-wide' 'two non-consecutive instance-wide stops pass' \
  probe.log quiet.log disabled.log
check 0 '^CUSTODY OK: 1 log\(s\), 1 instance-wide' 'a refused boot is one instance-wide stop' \
  boot-refused.log
check 1 '^CUSTODY ALERT: instance-wide custody stop in two consecutive logs: boot-refused.log:5, then disabled.log:5$' \
  'a refused boot then a runtime disable alert' boot-refused.log disabled.log
check 1 '^CUSTODY ALERT: player steve refused 2 times: steve.log:5, steve-upper.log:5$' \
  'one player in two logs, in different letter case, alerts' steve.log quiet.log steve-upper.log
check 1 '^CUSTODY ALERT: player alex refused 2 times: alex-twice.log:5, alex-twice.log:6$' \
  'one player twice in one log alerts' alex-twice.log
check 0 '^CUSTODY OK: 2 log\(s\), 0 instance-wide stop\(s\), 2 player refusal' 'two players pass' \
  steve.log alex.log
check 1 '^CUSTODY ALERT: unclassified custody emergency at reworded.log:5: ' \
  'an unclassified custody emergency alerts' quiet.log reworded.log
check 1 '^CUSTODY ALERT: unclassified custody emergency at unprefixed.log:5: ' \
  'a custody emergency without the plugin prefix alerts' quiet.log unprefixed.log
check 2 '^usage: ' 'no log is a usage error'
check 2 'cannot read missing.log' 'a missing log is an error, not a pass' quiet.log missing.log
check 2 'merged.log holds 2 boots' 'a log holding two boots is an error, not a pass' merged.log
check 2 'tail.log has no boot line .* earlier piece' \
  'a lifetime split across the archive is an error, not a pass' probe.log head.log tail.log
check 1 '^CUSTODY ALERT: instance-wide custody stop in two consecutive logs: probe.log:5, then joined.log:7$' \
  'a lifetime joined across the archive alerts' probe.log joined.log
check 2 'preboot.log has no boot line .* earlier piece' \
  'a later log with no boot line and no custody line is an error' quiet.log preboot.log
check 2 'tail.log has no boot line and holds a custody emergency' \
  'a first log with no boot line and a custody line is an error' tail.log quiet.log
check 0 '^CUSTODY OK: 2 log\(s\), 1 instance-wide' \
  'a first log with no boot line and no custody line passes' preboot.log probe.log

if [ "$failures" -ne 0 ] || [ "$ran" -ne "$expected" ]; then
  printf '%s case(s) failed, %s of %s expected case(s) ran\n' "$failures" "$ran" "$expected"
  exit 1
fi
echo 'custody-alert-check self-test passed'
