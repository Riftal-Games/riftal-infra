#!/usr/bin/env bash
# Self-test for RiftalDevFaults.php (riftal-infra#932), ADR 017 P8's hook.
#
# Boots the pinned core image four times on one throwaway /data volume, with
# the shipped RiftalDevBots.php and RiftalDevFaults.php beside
# DevFaultsCustody.php, a fixture named RiftalCustody that enables at STARTUP
# as custody does. The fixture records whether the probe path is a directory
# when it enables, arms both faults through the console commands, saves two
# players through core and writes the probe the way custody does.
#
# The last boot runs a copy without @loadbefore RiftalCustody and expects the
# fixture to see the directory the boot before armed, so the check is known to
# tell the load orders apart on every run. Core shuffles the plugin directory
# before ordering it, so that boot's fixture also loads before RiftalDevBots,
# which RiftalDevFaults depends on, or the order would be a coin toss.
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

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=5
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
volume="riftal_smoke_dev_faults_$$_$RANDOM"
docker volume create "$volume" >/dev/null
trap 'rm -rf "$work"; docker volume rm "$volume" >/dev/null' EXIT

# $1 RiftalDevFaults.php to load, $2 RIFTAL_DEV_ENV, $3 FAULTS_ARM_PROBE,
# $4 a boot number that keeps each boot's player names its own, $5 the
# fixture, DevFaultsCustody.php when omitted; prints the fixture's result line,
# or the log tail when there is none
boot() {
  local plugins="$work/plugins-$4" name="riftal_selftest_dev_faults_$$_$RANDOM" log
  mkdir -p "$plugins"
  cp "$DIR/../RiftalDevBots.php" "$plugins/"
  cp "${5:-$DIR/DevFaultsCustody.php}" "$plugins/DevFaultsCustody.php"
  cp "$1" "$plugins/RiftalDevFaults.php"
  chmod -R a+rX "$plugins"
  if ! log="$(timeout 180 docker run --rm --pull never --name "$name" -m 2g --cpus 2 \
      -v "$plugins:/plugins:ro" -v "$volume:/data" \
      -e "RIFTAL_DEV_ENV=$2" -e "FAULTS_ARM_PROBE=$3" -e "FAULTS_BOOT=$4" \
      -e "POCKETMINE_ARGS=--xbox-auth=false --riftal-dev-bots=on --auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" 2>&1)"; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
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

printf '\n== gated: the named player is not saved, another is, and the probe throws\n'
expect "both faults hold on a dev-shaped boot" \
  "dir_at_enable=no commands=yes failing=unsaved other=saved probe=throws" "$(boot "$PLUGIN" 1 1 1)"

printf '\n== RIFTAL_DEV_ENV unset: no command, no listener, nothing cleared\n'
expect "a production-shaped boot has no hook and leaves the directory alone" \
  "dir_at_enable=yes commands=no failing=saved other=saved probe=throws" "$(boot "$PLUGIN" "" 1 2)"

printf '\n== the shipped plugin clears the armed directory before custody enables\n'
expect "custody's boot probe finds the directory gone, and it can be armed again" \
  "dir_at_enable=no commands=yes failing=unsaved other=saved probe=throws" "$(boot "$PLUGIN" 1 1 3)"

printf '\n== without @loadbefore RiftalCustody, custody enables before the clear\n'
copy="$work/no-loadbefore.php"
fixture="$work/custody-first.php"
grep -v '^ \* @loadbefore RiftalCustody$' "$PLUGIN" > "$copy" || true
sed 's/^ \* @load STARTUP$/&\n * @loadbefore RiftalDevBots/' "$DIR/DevFaultsCustody.php" > "$fixture"
if [ "$(grep -c '@loadbefore' "$copy")" = 0 ] && [ "$(grep -c '@loadbefore' "$PLUGIN")" = 1 ] \
    && [ "$(grep -c '@loadbefore RiftalDevBots' "$fixture")" = 1 ]; then
  pass "the copy drops exactly the @loadbefore line and the fixture loads first"
else
  fail "could not find the @loadbefore RiftalCustody line in $PLUGIN or the @load line in the fixture"
fi
expect "the copy leaves the armed directory for custody's boot probe to hit" \
  "dir_at_enable=yes commands=yes failing=unsaved other=saved probe=writes" "$(boot "$copy" 1 0 4 "$fixture")"

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
printf 'all %s assertions passed: one named player fails to save and the probe fails, only on a dev-shaped boot, and the next boot clears the probe before custody enables.\n' "$PASSES"
