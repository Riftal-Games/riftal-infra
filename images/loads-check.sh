#!/usr/bin/env bash
# The LOADS verdict read from one instance's boot log, with ADR 013's P13
# (riftal-pm docs/decisions/013-item-yielding-entities-are-never-saved.md):
# the boot reached Done, logged nothing above WARNING, and enabled
# RiftalCustody before it prepared any world.
#
# Core enables STARTUP plugins before it loads or generates a world
# (pmmp-core src/Server.php:1067-1078), and World's constructor logs
# `Preparing world` for each one (src/world/World.php:507). A RiftalCustody
# enable after that line means a chunk could load with no sweep listening.
#
#   loads-check.sh <boot log>    exits 0 on a pass, 1 naming every failure
set -euo pipefail

log="${1:?usage: loads-check.sh <boot log>}"
if [ ! -r "$log" ]; then
  printf 'LOADS FAIL: cannot read %s\n' "$log"
  exit 1
fi

failures=0
fail() { printf 'LOADS FAIL: %s\n' "$1"; failures=$((failures + 1)); }

# Line number of the first line matching $1, or nothing.
first() { grep -n -m1 -E "$1" "$log" | cut -d: -f1 || true; }

# PocketMine prints every severity as [<thread>/<LEVEL>], so a bare [ERROR]
# never matches (MainLogger.php:38 and :192).
severe="$(grep -c -E '/(EMERGENCY|ALERT|CRITICAL|ERROR)\]' "$log" || true)"
done_at="$(first '\]: Done \(')"
custody_at="$(first '\]: Enabling RiftalCustody v')"
world_at="$(first '\]: Preparing world "')"

[ -n "$done_at" ] || fail "the boot never reached Done"
[ "$severe" -eq 0 ] || fail "$severe line(s) logged above WARNING"
[ -n "$custody_at" ] || fail "RiftalCustody was never enabled"
[ -n "$world_at" ] || fail "no world was prepared, so the enable order cannot be read"
if [ -n "$custody_at" ] && [ -n "$world_at" ] && [ "$custody_at" -gt "$world_at" ]; then
  fail "RiftalCustody enabled on line $custody_at, after the first world was prepared on line $world_at"
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'LOADS PASS: Done on line %s, RiftalCustody enabled on line %s before the first world on line %s\n' \
  "$done_at" "$custody_at" "$world_at"
