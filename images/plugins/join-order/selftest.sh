#!/usr/bin/env bash
# Self-test that RiftalDevBots' return to spawn never undoes another plugin's
# placement (riftal-infra#331, riftal-infra#369), and that neither a stale
# same-name session's teleport (riftal-infra#455) nor a refused placement
# (riftal-infra#456) suppresses it.
#
# A plugin that places players on join at NORMAL, as RiftalMines' join_teleport
# does, or on login, as ranks' login-spawn teleport will (riftal-game#222), must
# decide where the bot ends up. This boots the real core image with the shipped
# RiftalDevBots.php and JoinOrderProbe.php beside it. The probe dispatches four
# bot sessions through PocketMine's own handler lists, one placed on join, one
# placed on login, one reconnecting while its stale session is teleported, and
# one whose login placement another listener cancels, logs every teleport that
# went through in the order the handlers made it, and shuts the server down.
#
# Two things keep a placement standing, and each control removes one so the
# check is known to tell them apart on every run. Without the teleport watch,
# the spawn return lands after a login placement. Without the watch and with
# the join handler at NORMAL or MONITOR, it lands after a join placement.
# NORMAL ties with the placer, and the probe registers first so the tie goes
# against RiftalDevBots.
#
# Runs the pinned core image from ../../core-image.sha, present only on the
# self-hosted runners' Docker daemon. It publishes no port and keeps nothing:
# /data is the container's own anonymous volume, removed with it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$DIR/../RiftalDevBots.php"
PROBE="$DIR/JoinOrderProbe.php"
. "$DIR/../../core-image.sh"
core_image || { printf 'the join order was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"
JOIN_LINE='registerEvent(PlayerJoinEvent::class, $this->onJoin(...), EventPriority::'
WATCH_LINE='registerEvent(EntityTeleportEvent::class, $this->onTeleport(...)'
WATCH_SHIPPED="${WATCH_LINE}, EventPriority::MONITOR, \$this);"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=14
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 RiftalDevBots.php to load; prints the probe's result lines, or the log
# tail when there are none
probe() {
  local plugins="$work/plugins-$RANDOM" name="riftal_selftest_join_order_$$_$RANDOM" log
  mkdir -p "$plugins"
  cp "$1" "$plugins/RiftalDevBots.php"
  cp "$PROBE" "$plugins/JoinOrderProbe.php"
  chmod -R a+rX "$plugins"
  if ! log="$(timeout 180 docker run --rm --pull never --name "$name" -m 2g --cpus 2 \
      -v "$plugins:/plugins:ro" -e RIFTAL_DEV_ENV=1 \
      -e "POCKETMINE_ARGS=--xbox-auth=false --riftal-dev-bots=on --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" 2>&1)"; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  if grep -qE 'CRITICAL|EMERGENCY|Exception|Stack trace' <<<"$log"; then
    printf 'server log has an error:\n%s\n' "$(grep -E 'CRITICAL|EMERGENCY|Exception|Stack trace' <<<"$log")"
    return
  fi
  grep -oE '(join-order|login-placement|stale-session|cancelled-login)-probe admitted=.*' <<<"$log" || tail -n 20 <<<"$log"
}

# $1 probe output, $2 session label; prints that session's line, or all of $1
session() {
  grep "^$2-probe " <<<"$1" || printf '%s\n' "$1"
}

printf '\n== the shipped plugin: the placer decides where the bot ends up\n'
result="$(probe "$PLUGIN")"
printf '%s\n' "$result"
line="$(session "$result" join-order)"
[ "$line" = "join-order-probe admitted=yes teleports=spawn,placer" ] \
  && pass "RiftalDevBots returns the bot to spawn first and the join placer has the last word" \
  || fail "expected the spawn return then the join placement, got: $line"
line="$(session "$result" login-placement)"
[ "$line" = "login-placement-probe admitted=yes teleports=login-placer" ] \
  && pass "a bot placed on login stays where the login placer put it" \
  || fail "expected only the login placement, got: $line"
line="$(session "$result" stale-session)"
[ "$line" = "stale-session-probe admitted=yes teleports=spawn" ] \
  && pass "a stale same-name session's teleport does not stop the new session's spawn return" \
  || fail "expected only the spawn return for the new session, got: $line"
line="$(session "$result" cancelled-login)"
[ "$line" = "cancelled-login-probe admitted=yes teleports=spawn" ] \
  && pass "a cancelled login placement does not count as placed, and the bot is returned to spawn" \
  || fail "expected only the spawn return after the cancelled login placement, got: $line"

printf '\n== without the teleport watch the spawn return undoes a login placement, and the probe sees it\n'
unwatched="$work/unwatched.php"
grep -vF "$WATCH_LINE" "$PLUGIN" > "$unwatched" || true
[ "$(grep -cF "$WATCH_LINE" "$PLUGIN")" = 1 ] && [ "$(grep -cF "$WATCH_LINE" "$unwatched")" = 0 ] \
  && pass "the unwatched copy drops the teleport watch's registration" \
  || fail "could not find the teleport watch's registration in $PLUGIN"
line="$(session "$(probe "$unwatched")" login-placement)"
printf '%s\n' "$line"
[ "$line" = "login-placement-probe admitted=yes teleports=login-placer,spawn" ] \
  && pass "unwatched, the probe sees the spawn return land after the login placement" \
  || fail "expected the login placement then the spawn return, got: $line"

# $1 a priority at which an unwatched spawn return undoes a join placement
control() {
  local copy="$work/$1.php" line
  printf '\n== unwatched, the join handler at %s undoes the join placement, and the probe sees it\n' "$1"
  sed "s/\(onJoin(\.\.\.), EventPriority::\)[A-Z]*/\1$1/" "$unwatched" > "$copy"
  [ "$(grep -cF "${JOIN_LINE}$1" "$copy")" = 1 ] \
    && pass "the $1 copy registers the join handler at $1" \
    || fail "could not find the join handler's registration in $PLUGIN"
  line="$(session "$(probe "$copy")" join-order)"
  printf '%s\n' "$line"
  [ "$line" = "join-order-probe admitted=yes teleports=placer,spawn" ] \
    && pass "at $1 the probe sees the spawn return land last" \
    || fail "expected the join placement then the spawn return at $1, got: $line"
}
control NORMAL
control MONITOR

# $1 label, $2 sed expression rewriting the watch's registration, $3 the
# registration it must leave behind
cancelled() {
  local copy="$work/watch-$1.php" line
  printf '\n== a watch %s counts the cancelled login placement, and the probe sees it\n' "$1"
  sed "$2" "$PLUGIN" > "$copy"
  [ "$(grep -cF "$WATCH_SHIPPED" "$PLUGIN")" = 1 ] && [ "$(grep -cF "$3" "$copy")" = 1 ] \
    && pass "the copy registers the teleport watch as $3" \
    || fail "could not rewrite the teleport watch's registration in $PLUGIN"
  line="$(session "$(probe "$copy")" cancelled-login)"
  printf '%s\n' "$line"
  [ "$line" = "cancelled-login-probe admitted=yes teleports=none" ] \
    && pass "a watch $1 skips the spawn return after a cancelled placement" \
    || fail "expected no teleport with a watch $1, got: $line"
}
cancelled "at LOWEST" 's/\(onTeleport(\.\.\.), EventPriority::\)MONITOR/\1LOWEST/' \
  "${WATCH_LINE}, EventPriority::LOWEST, \$this);"
cancelled "handling cancelled events" 's/\(onTeleport(\.\.\.), EventPriority::MONITOR, \$this\))/\1, true)/' \
  "${WATCH_LINE}, EventPriority::MONITOR, \$this, true);"

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
printf 'all %s assertions passed: a plugin placing players on join or on login has the last word over RiftalDevBots.\n' "$PASSES"
