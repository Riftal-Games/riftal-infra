#!/usr/bin/env bash
# Self-test for the order RiftalDevBots' join handler runs in (riftal-infra#331).
#
# A plugin that places players on join at NORMAL, as RiftalMines' join_teleport
# does, must have the last word over RiftalDevBots' return to spawn. This boots
# the real core image with the shipped RiftalDevBots.php and JoinOrderProbe.php
# beside it. The probe dispatches a bot's PlayerPreLoginEvent and
# PlayerJoinEvent through PocketMine's own handler lists, logs every teleport
# in the order the handlers made it, and shuts the server down.
#
# It then runs a copy with the join handler registered at MONITOR, the order
# that let the spawn return undo the placement, and expects the probe to see
# that, so the check is known to tell the two apart on every run.
#
# Needs the local-pocketmine-mp image, present on the self-hosted runners. It
# publishes no port and keeps nothing: /data is the container's own anonymous
# volume, removed with it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$DIR/../RiftalDevBots.php"
PROBE="$DIR/JoinOrderProbe.php"
IMAGE=local-pocketmine-mp
JOIN_LINE='registerEvent(PlayerJoinEvent::class, $this->onJoin(...), EventPriority::'

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=3
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { printf '::error::image %s is not present, so the join order was never checked\n' "$IMAGE"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 RiftalDevBots.php to load; prints the probe's result line, or the log
# tail when there is none
probe() {
  local plugins="$work/plugins-$RANDOM" name="riftal_selftest_join_order_$$_$RANDOM" log
  mkdir -p "$plugins"
  cp "$1" "$plugins/RiftalDevBots.php"
  cp "$PROBE" "$plugins/JoinOrderProbe.php"
  chmod -R a+rX "$plugins"
  if ! log="$(timeout 180 docker run --rm --name "$name" \
      -v "$plugins:/plugins:ro" -e RIFTAL_DEV_ENV=1 \
      -e "POCKETMINE_ARGS=--xbox-auth=false --riftal-dev-bots=on --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" 2>&1)"; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  if grep -qE 'CRITICAL|EMERGENCY|Exception|Stack trace' <<<"$log"; then
    printf 'server log has an error:\n%s\n' "$(grep -E 'CRITICAL|EMERGENCY|Exception|Stack trace' <<<"$log")"
    return
  fi
  grep -o 'join-order-probe admitted=.*' <<<"$log" || tail -n 20 <<<"$log"
}

printf '\n== the shipped plugin: a NORMAL placer decides where the bot ends up\n'
result="$(probe "$PLUGIN")"
printf '%s\n' "$result"
[ "$result" = "join-order-probe admitted=yes teleports=spawn,placer" ] \
  && pass "RiftalDevBots returns the bot to spawn first and the placer has the last word" \
  || fail "expected the spawn return then the placement, got: $result"

printf '\n== the join handler at MONITOR undoes the placement, and the probe sees it\n'
sed 's/\(onJoin(\.\.\.), EventPriority::\)[A-Z]*/\1MONITOR/' "$PLUGIN" > "$work/monitor.php"
[ "$(grep -cF "${JOIN_LINE}MONITOR" "$work/monitor.php")" = 1 ] \
  && pass "the MONITOR copy registers the join handler at MONITOR" \
  || fail "could not find the join handler's registration in $PLUGIN"
result="$(probe "$work/monitor.php")"
printf '%s\n' "$result"
[ "$result" = "join-order-probe admitted=yes teleports=placer,spawn" ] \
  && pass "at MONITOR the probe sees the spawn return land last" \
  || fail "expected the placement then the spawn return, got: $result"

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
printf 'all %s assertions passed: a plugin placing players on join at NORMAL has the last word over RiftalDevBots.\n' "$PASSES"
