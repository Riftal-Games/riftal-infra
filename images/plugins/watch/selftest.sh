#!/usr/bin/env bash
# Self-test for RiftalDevBots' /watch camera follow (riftal-infra#115).
#
# This boots the real core image with the shipped RiftalDevBots.php and
# WatchProbe.php beside it. The probe stands up one bot and four viewers
# through core's own login, join and quit events, and stands in for each
# viewer's network session with one that records the packets the core would
# have sent. The viewers then use the real /watch command through core's own
# command dispatch, and the plugin's own repeating task moves the cameras.
#
# What the shipped plugin must do: send the camera presets and then a camera
# set at the bot's eyes on every tick; send a clear on /watch alone and when
# the watched bot quits; send nothing to a viewer that quits; refuse a name
# that is not an admitted dev bot; leave /watch unregistered where bots are
# not admitted. And a camera send that throws, which on the scheduler would
# stop the whole server, must release only that viewer's watch and be logged,
# while the other viewers keep their camera.
#
# Each control removes one thing the shipped plugin does, so every assertion
# is known to fail on a plugin without it:
#   - the guard around the camera send: the exception reaches the scheduler,
#     and the log shows the server going down;
#   - the repeating task: the viewer gets presets and a clear, and no camera;
#   - the one-tick period: the camera sets are not on consecutive ticks;
#   - the quit handler: the bot's watchers learn of it from the poll, as
#     "is gone", and not as "left".
#
# Runs the pinned core image from ../../core-image.sha, present only on the
# self-hosted runners' Docker daemon. It publishes no port and keeps nothing:
# /data is the container's own anonymous volume, removed with it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$DIR/../RiftalDevBots.php"
PROBE="$DIR/WatchProbe.php"
. "$DIR/../../core-image.sh"
core_image || { printf 'the camera follow was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=16
FATAL='CRITICAL|EMERGENCY|Exception|Stack trace'
GUARD='catch(Throwable $e){'
TASK='scheduleRepeatingTask(new ClosureTask($this->watch->moveCameras(...)), 1);'
QUIT='$this->watch?->onQuit($player);'
BOTS='--riftal-dev-bots=on'
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 RiftalDevBots.php to load, $2 the dev bots flag or empty; sets LOG to the
# server log and STATUS to the container's exit status.
#
# A crashed server shuts itself down, then sleeps out the rest of two minutes
# to throttle automatic restarts, saying at that point that the process can be
# killed safely. The wait is stopped there instead of being run out.
boot() {
  local plugins="$work/plugins-$RANDOM" name="riftal_selftest_watch_$$_$RANDOM" file pid
  file="$work/log-$RANDOM"
  mkdir -p "$plugins"
  cp "$1" "$plugins/RiftalDevBots.php"
  cp "$PROBE" "$plugins/WatchProbe.php"
  chmod -R a+rX "$plugins"
  timeout 180 docker run --rm --pull never --name "$name" -m 2g --cpus 2 \
      -v "$plugins:/plugins:ro" -e RIFTAL_DEV_ENV=1 \
      -e "POCKETMINE_ARGS=--xbox-auth=false $2 --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" >"$file" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if grep -q 'to throttle automatic restart' "$file"; then
      docker stop -t 1 "$name" >/dev/null 2>&1 || true
      break
    fi
    sleep 0.5
  done
  STATUS=0
  wait "$pid" || STATUS=$?
  LOG="$(cat "$file")"
  if [ "$STATUS" -ne 0 ]; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
}

# $1 session label; prints that viewer's line from LOG without its prefix
viewer() {
  grep -oE "watch-probe $1 .*" <<<"$LOG" | cut -d' ' -f3- || true
}

# $1 label, $2 the exact expected line of that viewer
expect() {
  local line
  line="$(viewer "$1")"
  [ "$line" = "$2" ] && pass "$1: $2" || fail "$1: expected '$2', got '$line'"
}

# $1 sed expression, $2 the line it must remove, $3 the file to write
mutate() {
  sed "$1" "$PLUGIN" > "$3"
  [ "$(grep -cF "$2" "$PLUGIN")" = 1 ] && [ "$(grep -cF "$2" "$3")" = 0 ] \
    && pass "the copy no longer has: $2" \
    || fail "could not remove '$2' from $PLUGIN"
}

BOT_ADDED='Watching WatchBot. /watch to return.'
printf '\n== the shipped plugin\n'
boot "$PLUGIN" "$BOTS"
printf '%s\n' "$LOG" | grep -E 'watch-probe|RiftalDevBots\]' || printf '%s\n' "$LOG" | tail -n 20
if grep -qE "$FATAL" <<<"$LOG"; then
  fail "the server log has an error: $(grep -E "$FATAL" <<<"$LOG" | head -n 3)"
elif [ "$STATUS" -eq 0 ] && grep -q 'watch-probe done' <<<"$LOG"; then
  pass "the probe ran to its end and the server stopped cleanly"
else
  fail "the probe did not finish or the server did not stop, exit status $STATUS"
fi
grep -q 'watch-probe registered=yes permission=granted' <<<"$LOG" \
  && pass "/watch is registered and the user group holds its permission" \
  || fail "expected /watch registered with its permission granted"
expect ViewerA "sent=presets,set+,clear continuous=yes eyes=yes says=Dev bots online: WatchBot|No dev bot called Nobody is online.|No dev bot called ViewerC is online.|$BOT_ADDED|Stopped watching: back to your own view."
expect ViewerC "sent=presets,set+,clear continuous=yes eyes=yes says=$BOT_ADDED|Stopped watching: WatchBot left."
expect ViewerD "sent=presets,set+,quit continuous=yes eyes=yes says=$BOT_ADDED"
expect ViewerB "sent=presets,fault continuous=yes eyes=none says=$BOT_ADDED"
[ "$(grep -c 'watch: camera released for ViewerB: probe camera fault' <<<"$LOG")" = 1 ] \
  && pass "the failed camera send was logged once, and not retried each tick" \
  || fail "expected one camera released line for ViewerB"

printf '\n== where bots are not admitted there is no /watch\n'
boot "$PLUGIN" ""
grep -E 'watch-probe' <<<"$LOG" || tail -n 20 <<<"$LOG"
grep -q 'watch-probe registered=no' <<<"$LOG" && grep -q 'watch-probe done' <<<"$LOG" && [ "$STATUS" -eq 0 ] \
  && pass "without the dev bots flag /watch is not registered" \
  || fail "expected /watch unregistered and a clean stop, exit status $STATUS"

printf '\n== without the guard the failed camera send reaches the scheduler, and the log shows the server going down\n'
mutate 's/catch(Throwable \$e){/catch(\\Riftal\\NeverThrown $e){/' "$GUARD" "$work/unguarded.php"
boot "$work/unguarded.php" "$BOTS"
grep -E 'CRITICAL|EMERGENCY' <<<"$LOG" | head -n 3 || true
grep -qE 'CRITICAL|EMERGENCY' <<<"$LOG" && ! grep -q 'watch-probe done' <<<"$LOG" \
  && pass "unguarded, the server logs a fatal error and the probe never finishes" \
  || fail "expected the unguarded copy to take the server down"

printf '\n== without the repeating task nothing moves the camera\n'
mutate "/scheduleRepeatingTask(new ClosureTask(\$this->watch->moveCameras/d" "$TASK" "$work/untasked.php"
boot "$work/untasked.php" "$BOTS"
expect ViewerA "sent=presets,clear continuous=yes eyes=none says=Dev bots online: WatchBot|No dev bot called Nobody is online.|No dev bot called ViewerC is online.|$BOT_ADDED|Stopped watching: back to your own view."

printf '\n== a camera set only every second tick is not continuous\n'
mutate 's/\(scheduleRepeatingTask(new ClosureTask(\$this->watch->moveCameras(\.\.\.)), \)1);/\12);/' "$TASK" "$work/slow.php"
boot "$work/slow.php" "$BOTS"
expect ViewerC "sent=presets,set+,clear continuous=no eyes=yes says=$BOT_ADDED|Stopped watching: WatchBot left."

printf '\n== without the quit handler the bot leaving is only noticed by the poll\n'
mutate '/\$this->watch?->onQuit(\$player);/d' "$QUIT" "$work/unquit.php"
boot "$work/unquit.php" "$BOTS"
expect ViewerC "sent=presets,set+,clear continuous=yes eyes=yes says=$BOT_ADDED|Stopped watching: WatchBot is gone."

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
printf 'all %s assertions passed: /watch follows a bot every tick, ends cleanly, and a failed camera send cannot stop the server.\n' "$PASSES"
