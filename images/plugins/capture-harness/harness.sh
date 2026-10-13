#!/usr/bin/env bash
# In-server harness for RiftalCapture.php (riftal-infra#553, ADR 015 items 1, 2
# and 8). capture-selftest.sh runs the plugin against fakes of the core; this
# boots the real local-pocketmine-mp image in instance-b's shape with this
# tree's plugins, where World::save's force gate and the shutdown order
# (plugins disabled, then worlds unloaded with an unforced save) are the
# core's own. It drives captures through a bind-mounted /capture and the
# console, and asserts on the server log and the files under /data.
# CaptureProbe.php logs the autosave flag the server actually holds.
#
# CAPTURE_PLUGIN names another RiftalCapture.php to load in place of this
# tree's, which is how a mutant is shown to go red here.
#
# Publishes no port. Every container and volume it makes is named
# riftal_smoke_capture_*, and the EXIT trap stops the server with `stop` on
# stdin and removes both, on a failure too. Cleanup on a cancelled or
# timed-out job is not guaranteed: the runner follows INT and TERM with
# SIGKILL within seconds, which ends the trap before it can finish
# (riftal-infra#509).
#
# Each condition reaches check single-quoted and is expanded by its eval, so
# the variables it names are read there.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS="$(cd "$DIR/.." && pwd)"
INDEX="$(cd "$DIR/../../../designer" && pwd)/world_index.json"
CAPTURE_PLUGIN="${CAPTURE_PLUGIN:-$PLUGINS/RiftalCapture.php}"
IMAGE=local-pocketmine-mp
TOOL=php:8.3-cli-alpine
LEVEL=/data/worlds/plots_b/level.dat
EXPECTED_ASSERTIONS=15

PASSES=0
FAILURES=0
# $1 what is claimed; $2 a condition, evaluated
check() {
  if eval "$2"; then
    printf 'ok %s\n' "$1"
    PASSES=$((PASSES + 1))
  else
    printf 'FAIL %s\n' "$1"
    FAILURES=$((FAILURES + 1))
  fi
}

for image in "$IMAGE" "$TOOL"; do
  docker image inspect "$image" >/dev/null 2>&1 \
    || { printf '::error::image %s is not present, so the capture was never booted\n' "$image"; exit 1; }
done

work="$(mktemp -d)"
name=""
pid=""
log=/dev/null
cap=""
exited=""

halt() {
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    echo stop >&3 || true
    for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  fi
  exec 3>&- || true
  if kill -0 "$pid" 2>/dev/null; then
    docker stop -t 30 "$name" >/dev/null 2>&1 || true
  fi
  exited=0
  wait "$pid" || exited=$?
  pid=""
}

cleanup() {
  halt
  if [ -n "$name" ]; then
    docker volume rm -f "$name" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# $1 a literal string; $2 how many times it must appear; $3 seconds to wait
await() {
  local deadline=$(($(date +%s) + $3))
  while [ "$(grep -cF -- "$1" "$log" || true)" -lt "$2" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

# $1 a label for this boot
boot() {
  local run="$work/$1"
  name="riftal_smoke_capture_$$_$1"
  log="$run/server.log"
  cap="$run/capture"
  mkdir -p "$run/plugins" "$cap"
  cp -R "$PLUGINS/." "$run/plugins/"
  cp "$CAPTURE_PLUGIN" "$run/plugins/RiftalCapture.php"
  cp "$DIR/CaptureProbe.php" "$run/plugins/"
  chmod -R a+rX "$run"
  mkfifo "$run/stdin"
  docker volume create "$name" >/dev/null
  docker run --rm -i --name "$name" -m 2g --cpus 2 \
    -v "$name:/data" -v "$run/plugins:/plugins:ro" -v "$cap:/capture:ro" \
    -v "$INDEX:/etc/riftal/world_index.json:ro" \
    -e INSTANCE_ID=capture-harness -e RIFTAL_DEV_ENV=1 \
    -e "POCKETMINE_ARGS=--level-name=plots_b --level-type=flat --xbox-auth=false --motd=riftal-capture-harness --riftal-dev-bots=on --auto-report.enabled=0" \
    "$IMAGE" bash /plugins/deliver-world-index.sh start-pocketmine <"$run/stdin" >"$log" 2>&1 &
  pid=$!
  exec 3>"$run/stdin"
  if ! await 'Done (' 1 120; then
    cat "$log"
    printf '::error::the %s boot never reached Done\n' "$1"
    exit 1
  fi
}

# $1 id; $2 seconds until its deadline. Written whole through a rename, as ADR 015 item 2 has backup.sh write it.
request() {
  printf '%s %s\n' "$1" "$(($(date +%s) + $2))" >"$cap/request.tmp"
  mv "$cap/request.tmp" "$cap/request"
}

autosave() {
  grep -oF -e '[CaptureProbe] autosave on' -e '[CaptureProbe] autosave off' "$log" | tail -n 1 | awk '{print $3}'
}

live() {
  docker exec "$name" sh -c "$1"
}

level_now() {
  live "sha256sum $LEVEL" | cut -d' ' -f1 || true
}

# After the server exits: the hash of level.dat, then whatever .capture still holds.
level_after() {
  docker run --rm -m 1g --cpus 1 -v "$name:/data:ro" "$TOOL" \
    sh -c "sha256sum $LEVEL | cut -d' ' -f1; ls -A /data/.capture 2>/dev/null; true"
}

# The log strictly between the first line holding $1 and the next holding $2.
between() {
  awk -v a="$1" -v b="$2" 'f && index($0, b) {exit} f; index($0, a) {f = 1}' "$log"
}

# $1 the boot's label: Done reached, both plugins enabled, nothing thrown, exit 0.
clean_log() {
  check "$1: RiftalCapture and CaptureProbe enabled, no error in the log, the server exited 0" \
    'grep -qF "Enabling RiftalCapture" "$log" && grep -qF "Enabling CaptureProbe" "$log" &&
     ! grep -qE "CRITICAL|EMERGENCY|ERROR|Exception|Stack trace|Fatal|Deprecated" "$log" &&
     [ "$exited" = 0 ]'
  if [ "$FAILURES" -ne 0 ]; then
    printf '\n== server log, %s\n' "$1"
    cat "$log"
  fi
}

printf '\n== boot one: a to d, and stop with nothing held\n'
boot one
live 'mkdir -p /data/players && for i in 1 2 3; do head -c 4000 /dev/urandom > /data/players/h$i.dat; done'
saved="$(level_now)"
request r1 600
await 'capture r1 held' 1 10 || true
sleep 1
check "a. the capture acks r1 and stages each player file byte for byte" \
  '[ "$(live "cat /data/.capture/r1/ack")" = r1 ] &&
   live "for i in 1 2 3; do cmp /data/players/h\$i.dat /data/.capture/r1/players/h\$i.dat || exit 1; done"'
check "a. the server holds autosave off through the hold" '[ "$(autosave)" = off ]'
check "a. the held tick force-saves the world, under autosave off" '[ "$(level_now)" != "$saved" ]'

rm -f "$cap/request"
await 'capture r1 released' 1 10 || true
sleep 1
check "b. deleting the request restores the server's autosave on" '[ "$(autosave)" = on ]'
check "b. deleting the request removes the staged copy" '! live "test -e /data/.capture/r1"'

request r2 4
await 'capture r2 held' 1 10 || true
request r2 600
await 'capture r2 released' 1 15 || true
sleep 3
check "c. the lease read at capture ends the hold with the request still in place, rewritten later" \
  'grep -qF "capture r2 released" "$log" && [ -e "$cap/request" ]'
check "c. autosave is back on and the staged copy is gone" \
  '[ "$(autosave)" = on ] && ! live "test -e /data/.capture/r2"'
check "c. r2 is not captured again, three polls after its lease" '[ "$(grep -cF "capture r2 held" "$log")" = 1 ]'
rm -f "$cap/request"

echo save-off >&3
await 'Turned off world auto-saving' 1 10 || true
request r3 600
await 'capture r3 held' 1 10 || true
rm -f "$cap/request"
await 'capture r3 released' 1 10 || true
echo save-on >&3
await 'Turned on world auto-saving' 1 10 || true
sleep 1
saved="$(level_now)"
halt
check "d. save-on after a release, then stop: no RiftalCapture line between Disabling RiftalCapture and Stopping other threads" \
  'grep -qF "Stopping other threads" "$log" &&
   [ -z "$(between "Disabling RiftalCapture" "Stopping other threads" | grep -F "[RiftalCapture]")" ]'
check "d. autosave stays on through the unload, so the unload save writes level.dat" \
  '[ "$(level_after | head -n 1)" != "$saved" ]'
clean_log one
docker volume rm "$name" >/dev/null

printf '\n== boot two: e, stop during a hold\n'
boot two
request e1 600
await 'capture e1 held' 1 10 || true
sleep 1
check "e. the hold is taken, autosave off" '[ "$(autosave)" = off ]'
saved="$(level_now)"
halt
check "e. stop during the hold releases e1 with autosave on, before the worlds unload" \
  'between "Disabling RiftalCapture" "Unloading world" | grep -qF "capture e1 released, autosave on"'
after="$(level_after)"
check "e. the unload save writes level.dat, and .capture is left empty" \
  '[ "$(head -n 1 <<<"$after")" != "$saved" ] && [ "$(wc -l <<<"$after")" = 1 ]'
clean_log two

ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '::error::%s of %s assertions ran, so one did not run and cannot have passed\n' "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '::error::%s harness assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed on the real core: a capture under autosave off, release on delete, on the lease and on stop, and a stop with nothing held that leaves autosave alone.\n' "$PASSES"
