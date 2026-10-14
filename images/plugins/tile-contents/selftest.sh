#!/usr/bin/env bash
# Self-test for RiftalDevBots' devbots-tile command (riftal-infra#1105), the
# server-side tile contents ADR 025 P5 and spec 020's M3 criteria compare a
# bot's client view with.
#
# Boots the real core image with the shipped RiftalDevBots.php and
# TileContentsProbe.php beside it. The probe fills a furnace and asks for it
# slot by slot as the console, in the default level and by name, then for
# air and for a chunk nothing holds loaded, which is reported without being
# read, and as an operator who is not a dev bot and must be refused. Last it
# reads the furnace inventory itself, which must hold what it was filled with.
# Without
# the --riftal-dev-bots=on flag, or without RIFTAL_DEV_ENV=1, the command
# does not exist.
#
# Runs the pinned core image from ../../core-image.sha, present only on the
# self-hosted runners' Docker daemon. It publishes no port and keeps nothing:
# /data is the container's own anonymous volume, removed with it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../core-image.sh"
core_image || { printf 'the tile contents surface was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"
ERRORS='CRITICAL|EMERGENCY|Exception|Stack trace'

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=13
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
plugins="$work/plugins"
mkdir -p "$plugins"
cp "$DIR/../RiftalDevBots.php" "$DIR/TileContentsProbe.php" "$plugins/"
chmod -R a+rX "$plugins"

# $1 --riftal-dev-bots value, $2 RIFTAL_DEV_ENV value ("" for unset); leaves
# the log in $work/log, the command's lines with each tick as N in
# $work/lines, and the probe's position line's fields in $at
boot() {
  local name="riftal_selftest_tile_contents_$$_$RANDOM"
  local env=()
  [ -n "$2" ] && env=(-e "RIFTAL_DEV_ENV=$2")
  status=0
  timeout 180 docker run --rm --pull never --name "$name" -m 2g --cpus 2 \
      -v "$plugins:/plugins:ro" "${env[@]}" \
      -e "POCKETMINE_ARGS=--xbox-auth=false --riftal-dev-bots=$1 --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" >"$work/log" 2>&1 || status=$?
  if [ "$status" -eq 124 ]; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  grep -F '[RiftalDevBots]' "$work/log" | grep -o 'devbots-tile .*' \
    | sed 's/tick=[0-9]*/tick=N/' >"$work/lines" || true
  at="$(grep -o 'tile-probe at .*' "$work/log" | sed 's/^tile-probe at //; s/ registered=.*//' || true)"
  grep -E 'tile-probe|devbots-tile' "$work/log" || tail -n 20 "$work/log"
  printf 'exit status %s\n' "$status"
}

clean() {
  ! grep -qE "$ERRORS" "$work/log" && [ "$status" -eq 0 ] \
    && pass "$1: the server stops cleanly with no error in its log" \
    || fail "$1: exit $status, or an error in the log: $(grep -E "$ERRORS" "$work/log" || true)"
}

# $1 what is shown, $2 the line expected in $work/lines
has() {
  grep -qxF "$2" "$work/lines" && pass "$1" || fail "$1: no line '$2'"
}

printf '\n== dev bots admitted: the console reads a tile slot by slot\n'
boot on 1
clean "admitted"
grep -q 'tile-probe at .* registered=yes' "$work/log" \
  && pass "devbots-tile is registered" \
  || fail "devbots-tile is not registered with dev bots admitted"
read -r level x y z <<<"$at"
has "the furnace is named with its slot count" "devbots-tile $level $x $y $z tick=N tile=NormalFurnace slots=3"
has "slot 0 holds the raw iron" "devbots-tile $level $x $y $z slot=0 id=minecraft:raw_iron meta=0 count=5 nbt=no"
has "slot 1 is empty" "devbots-tile $level $x $y $z slot=1 empty"
has "slot 2 holds the ingots" "devbots-tile $level $x $y $z slot=2 id=minecraft:iron_ingot meta=0 count=3 nbt=no"
furnace="$(grep "^devbots-tile $level $x $y $z " "$work/lines" || true)"
[ "$(printf '%s\n' "$furnace" | wc -l)" = 8 ] \
  && [ "$(printf '%s\n' "$furnace" | sed -n 1,4p)" = "$(printf '%s\n' "$furnace" | sed -n 5,8p)" ] \
  && pass "the default level and the named level give the same four lines" \
  || fail "the two reads of the furnace differ, or are not four lines each: $furnace"
grep -qxF 'tile-probe after 0=Raw Iron x5, 1=empty, 2=Iron Ingot x3' <(grep -o 'tile-probe after .*' "$work/log") \
  && pass "every read leaves the furnace as it was filled" \
  || fail "the furnace changed under devbots-tile: $(grep -o 'tile-probe after .*' "$work/log" || true)"
has "air holds no tile" "devbots-tile $level $x $((y + 1)) $z tick=N no tile"
has "a chunk nothing holds is reported, not read" "devbots-tile $level 100000 70 100000 tick=N chunk not loaded"
grep -q 'tile-probe operator heard: devbots-tile runs only from the server console or a dev bot' "$work/log" \
  && pass "an operator who is not a dev bot is refused" \
  || fail "the operator was not refused"

# $1 --riftal-dev-bots value, $2 RIFTAL_DEV_ENV value, $3 description
absent() {
  printf '\n== %s: devbots-tile does not exist\n' "$3"
  boot "$1" "$2"
  grep -q 'tile-probe at .* registered=no' "$work/log" && [ ! -s "$work/lines" ] && [ "$status" -eq 0 ] \
    && pass "$3: devbots-tile is not registered, prints nothing and the server stops cleanly" \
    || fail "$3: devbots-tile is registered, printed, or the server did not stop cleanly (exit $status)"
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
printf 'all %s assertions passed: devbots-tile reads a tile slot by slot, only with dev bots admitted.\n' "$PASSES"
