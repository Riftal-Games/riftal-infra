#!/usr/bin/env bash
# Self-test for RiftalDevProofs.php (riftal-infra#1537), the effects proof
# sender of docs/effects/plan.md section 10.
#
# Boots the pinned core image six times on one throwaway /data volume, with
# the shipped RiftalDevBots.php and RiftalDevProofs.php beside ProofsProbe.php.
# The probe builds and encodes every packet of the sequence, joins a dev bot
# and then a client through PocketMine's own PlayerJoinEvent, runs the whole
# sequence at 50 times speed, and sends the settings request and two form
# answers through DataPacketReceiveEvent, as a client's Settings screen does.
# The packets are recorded on a session with no socket, so the self-test holds
# what is sent and logged, not what a client renders, which is the journey's.
#
# Every boot but the second sets RIFTAL_DEV_PROOFS=1, the plugin's opt-in on
# top of the dev gate. The first is gated open. The second is gated open with
# the opt-in unset, as the shared dev stack is, and must register no listener
# and send nothing. The third leaves RIFTAL_DEV_ENV unset and the fourth leaves
# --riftal-dev-bots off, so the opt-in alone admits nothing. The fifth leaves
# RiftalDevBots out, and core must refuse RiftalDevProofs. The sixth runs a
# copy that ignores its gate on a closed boot, so the closed-boot check is
# known to see it.
#
# It also holds that the release image does not carry the plugin: the
# allowlist the image copies from names no dev plugin, and nothing under
# images/release does either.
#
# Runs the pinned core image from ../../core-image.sha, present only on the
# self-hosted runners' Docker daemon. It publishes no port, and the volume is
# a riftal_smoke_ one removed on exit.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
PLUGIN="$DIR/../RiftalDevProofs.php"
. "$DIR/../../core-image.sh"
core_image || { printf 'the dev proof sender was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=22
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
volume="riftal_smoke_dev_proofs_$$_$RANDOM"
docker volume create "$volume" >/dev/null
trap 'rm -rf "$work"; docker volume rm "$volume" >/dev/null' EXIT

# $1 RiftalDevProofs.php to load, $2 RIFTAL_DEV_ENV, $3 a boot number, $4
# "nobots" to leave RiftalDevBots out, "noflag" to leave --riftal-dev-bots off
# or "noproofs" to leave RIFTAL_DEV_PROOFS unset. Keeps the log at $work/log-$3
# and prints the probe's lines, or the log tail when there are none.
boot() {
  local plugins="$work/plugins-$3" name="riftal_selftest_dev_proofs_$$_$RANDOM" log flag="--riftal-dev-bots=on" optin=(-e RIFTAL_DEV_PROOFS=1)
  mkdir -p "$plugins"
  [ "${4:-}" = nobots ] || cp "$DIR/../RiftalDevBots.php" "$plugins/"
  [ "${4:-}" != noflag ] || flag=""
  [ "${4:-}" != noproofs ] || optin=()
  cp "$DIR/ProofsProbe.php" "$plugins/ProofsProbe.php"
  cp "$1" "$plugins/RiftalDevProofs.php"
  chmod -R a+rX "$plugins"
  if ! log="$(timeout 180 docker run --rm --pull never --name "$name" -m 2g --cpus 2 \
      -v "$plugins:/plugins:ro" -v "$volume:/data" \
      -e "RIFTAL_DEV_ENV=$2" ${optin[@]+"${optin[@]}"} \
      -e "POCKETMINE_ARGS=--xbox-auth=false $flag --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" 2>&1)"; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$log" > "$work/log-$3"
  if grep -qE '/(EMERGENCY|ALERT|CRITICAL|ERROR)]|Exception|Stack trace' <<<"$log"; then
    printf 'server log has an error:\n%s\n' "$(grep -E '/(EMERGENCY|ALERT|CRITICAL|ERROR)]|Exception|Stack trace' <<<"$log")"
    return
  fi
  grep -o 'dev-proofs-probe .*' <<<"$log" || tail -n 20 <<<"$log"
}

# $1 a boot number, $2 an extended regex; prints how many log lines match it
count() { grep -cE "$2" "$work/log-$1" || true; }

# $1 what the boot shows, $2 a boot number, $3 the exact probe line wanted
probe_line() {
  local got
  got="$(grep -o 'dev-proofs-probe .*' "$work/log-$2" | grep -F -x -- "$3" || true)"
  [ -n "$got" ] && pass "$1" || fail "$1: boot $2 should log '$3', got: $(grep -o 'dev-proofs-probe .*' "$work/log-$2" || echo 'no probe line')"
}

step='\[RiftalDevProofs\] dev-proofs [0-9][a-z]?-[a-z-]+ player=ProofsProbe t=[0-9]{13} pos=10\.0,64\.0,10\.0 '
start='\[RiftalDevProofs\] dev-proofs start player=ProofsProbe t=[0-9]{13} steps=38 delay_seconds=20$'
closed='dev-proofs-probe sent=0 fog=0 shake=0 particle=0 sound=0 stop=0 bot_sent=0'
nosettings='dev-proofs-probe settings request_cancelled=no answered=no form_id=none rows= answer_cancelled=no other_form_cancelled=no'

printf '\n== gated open: both listeners register and the sequence is built, encoded and ordered\n'
boot "$PLUGIN" 1 1 >/dev/null
probe_line "the join and packet listeners are registered" 1 'dev-proofs-probe listeners join=1 packet=1'
probe_line "38 steps carry 33 packets, every one encodes, from 1a to the settings prompt" 1 \
  'dev-proofs-probe sequence steps=38 packets=33 sorted=yes empty_encodings=0 first=1a-vanilla-fog last=5-open-settings-now'

printf '\n== the sequence reaches a client, a dev bot gets none\n'
probe_line "a client is sent 6 fog, 1 shake, 15 particle, 9 sound and 2 stop packets, a bot none" 1 \
  'dev-proofs-probe sent=33 fog=6 shake=1 particle=15 sound=9 stop=2 bot_sent=0'
starts="$(count 1 "$start")"
steps="$(count 1 "$step")"
[ "$starts" = 2 ] && [ "$steps" = 38 ] \
  && pass "the log has two start lines, one for the join and one for the fast run, and 38 timestamped step lines" \
  || fail "boot 1 should log 2 start lines and 38 step lines, got $starts and $steps"
fog1="$(count 1 'PlayerFog layers=\[minecraft:fog_hell\]')"
fog2="$(count 1 'PlayerFog layers=\[riftal:proof_fog\]')"
[ "$fog1" = 2 ] && [ "$fog2" = 1 ] && [ "$(count 1 'sent=PlayerFog layers=\[\]$')" = 2 ] \
  && [ "$(count 1 'PlayerFog layers=\[minecraft:fog_the_end\]')" = 1 ] \
  && pass "proof 1 logs a vanilla fog, the pack fog, two empty stacks and the switch from one stack to another" \
  || fail "boot 1 proof 1 lines are wrong: vanilla=$fog1 pack=$fog2 empty=$(count 1 'sent=PlayerFog layers=\[\]$')"
[ "$(count 1 'CameraShake intensity=1.00 duration=2.00 type=1 action=0$')" = 1 ] \
  && pass "proof 2 logs one 2 second shake" || fail "boot 1 should log one 2 second shake"
ash="$(count 1 'SpawnParticleEffect name=bbstudio:ash_burst pos=13\.00,65\.00,10\.00 molang=none$')"
dust='SpawnParticleEffect name=riftal:proof_dust pos=13\.00,65\.00,10\.00 molang='
red="$(count 1 "$dust"'\[\{"name":"variable\.r","value":\{"type":"float","value":1.0\}\},\{"name":"variable\.g","value":\{"type":"float","value":0\.1\}\},\{"name":"variable\.b","value":\{"type":"float","value":0\.1\}\}\]$')"
blue="$(count 1 "$dust"'\[\{"name":"variable\.r","value":\{"type":"float","value":0\.1\}\},\{"name":"variable\.g","value":\{"type":"float","value":0\.3\}\},\{"name":"variable\.b","value":\{"type":"float","value":1.0\}\}\]$')"
[ "$ash" = 5 ] && [ "$red" = 5 ] && [ "$blue" = 5 ] \
  && pass "proof 3 logs five bursts at the sent position and five dust sends in each of two colours passed as Molang" \
  || fail "boot 1 proof 3 should log 5 bursts, 5 red and 5 blue dust sends, got $ash, $red and $blue"
tone='PlaySound name=riftal\.proof\.tone'
near="$(count 1 "$tone pos=10\.00,64\.00,10\.00 volume=1\.00 pitch=1\.00 loopCount=0 bypassListenerRangeCheck=no\$")"
far="$(count 1 "$tone pos=110\.00,64\.00,10\.00 volume=1\.00 pitch=1\.00 loopCount=0 bypassListenerRangeCheck=(no|yes)\$")"
[ "$near" = 6 ] && [ "$far" = 2 ] && [ "$(count 1 "$tone pos=110\.00,64\.00,10\.00 .* bypassListenerRangeCheck=yes\$")" = 1 ] \
  && [ "$(count 1 "$tone pos=10\.00,64\.00,10\.00 volume=1\.00 pitch=1\.00 loopCount=3 ")" = 1 ] \
  && [ "$(count 1 'StopSound name=riftal\.proof\.tone stopAll=no$')" = 2 ] \
  && pass "proof 4 logs the tone by name, the re-sent segments, a loop count, a far sound with and without the bypass, and two stops" \
  || fail "boot 1 proof 4 lines are wrong: near=$near far=$far"
[ "$(count 1 'dev-proofs 5-settings-request player=ProofsProbe t=[0-9]{13} answered with form id 1380319233$')" = 1 ] \
  && [ "$(count 1 'dev-proofs 5-settings-answer player=ProofsProbe t=[0-9]{13} data=\[1,2\] cancel_reason=none$')" = 1 ] \
  && pass "proof 5 logs the request it answered and the answer it received" \
  || fail "boot 1 should log one settings request and one answer, got: $(grep -E 'dev-proofs 5-settings' "$work/log-1" || echo none)"
probe_line "the settings form has the two rows, takes the request and its own answer and leaves another form's alone" 1 \
  'dev-proofs-probe settings request_cancelled=yes answered=yes form_id=fixed rows=dropdown:Full/Quiet/Off,dropdown:Full/Soft/Off answer_cancelled=yes other_form_cancelled=no'

printf '\n== gate open, RIFTAL_DEV_PROOFS unset: no listener, nothing sent, no settings answer\n'
boot "$PLUGIN" 1 2 noproofs >/dev/null
probe_line "a boot without the opt-in has no listener" 2 'dev-proofs-probe listeners join=0 packet=0'
probe_line "and sends nothing" 2 "$closed"
probe_line "and leaves the settings request to core" 2 "$nosettings"
[ "$(count 2 'dev-proofs [0-9a-z]')" = 0 ] && grep -q 'dev proofs off' "$work/log-2" \
  && pass "the log says dev proofs off and has no dev-proofs line" \
  || fail "boot 2 should say dev proofs off and log no dev-proofs line"

printf '\n== RIFTAL_DEV_ENV unset, opt-in set: the opt-in does not replace the gate\n'
boot "$PLUGIN" "" 3 >/dev/null
probe_line "a boot without the environment signal has no listener" 3 'dev-proofs-probe listeners join=0 packet=0'
probe_line "and sends nothing" 3 "$closed"

printf '\n== --riftal-dev-bots off, opt-in set: the same\n'
boot "$PLUGIN" 1 4 noflag >/dev/null
probe_line "a boot without the flag has no listener" 4 'dev-proofs-probe listeners join=0 packet=0'
probe_line "and sends nothing" 4 "$closed"

printf '\n== without RiftalDevBots: core refuses RiftalDevProofs, so no hook runs\n'
boot "$PLUGIN" 1 5 nobots >/dev/null
grep -qE "/CRITICAL\]: .*RiftalDevProofs.*RiftalDevBots" "$work/log-5" \
  && ! grep -qE 'dev proofs (on|off)|dev-proofs ' "$work/log-5" \
  && pass "a boot without RiftalDevBots names the missing dependency and loads no hook" \
  || fail "a boot without RiftalDevBots should refuse RiftalDevProofs for the missing dependency"

printf '\n== a copy that ignores its gate registers a listener on a closed boot\n'
copy="$work/ignores-gate.php"
sed 's/if(!\$this->on){/if(false){/' "$PLUGIN" > "$copy"
[ "$(grep -c 'if(false){' "$copy")" = 2 ] && [ "$(grep -c 'if(!\$this->on){' "$PLUGIN")" = 2 ] \
  && pass "the copy ignores the gate at exactly the two places it is read" \
  || fail "could not find exactly two gate checks in $PLUGIN"
boot "$copy" "" 6 >/dev/null
probe_line "the closed-boot check sees the copy's listeners" 6 'dev-proofs-probe listeners join=1 packet=1'

printf '\n== the release image does not carry it\n'
shipped="$(cd "$ROOT" && . deploy/release-image.sh && printf '%s\n' "${SHIPPED_PLUGINS[@]}")"
if ! grep -q 'RiftalDev' <<<"$shipped" && ! grep -rq 'RiftalDev' "$ROOT/images/release" && [ -n "$shipped" ]; then
  pass "the release allowlist names $(tr '\n' ' ' <<<"$shipped")and nothing under images/release names a dev plugin"
else
  fail "the release image would carry a dev plugin: $shipped"
fi

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
printf 'all %s assertions passed: the proof sequence is built, sent and logged, and the settings form answered, only on a dev-shaped boot that opts in, and the release image does not carry it.\n' "$PASSES"
