#!/usr/bin/env bash
# Self-test for RiftalDevBots.php's admission guard (riftal-infra#113).
#
# DevEnvGate::shouldAdmit() is declared with no PocketMine type in its
# signature, so this loads the real, shipped plugin file directly, catches
# the expected "PluginBase not found" Error once execution reaches the Main
# class (there is no PocketMine SDK here, only the plugin file), and then
# calls the gate exactly as onEnable() does. Runs inside php:8.3-cli-alpine,
# the same pinned image .github/workflows/ci.yml's "Lint PHP plugins" step
# already uses; not runnable on Nasir's Windows machine, which has no docker,
# only wslc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$SCRIPT_DIR/RiftalDevBots.php"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=6
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

# $1 flag requested, $2 requires-auth, $3 RIFTAL_DEV_ENV value ("" for unset)
gate() {
  docker run --rm -v "$PLUGIN:/plugin.php:ro" \
    -e "CASE_REQUESTED=$1" -e "CASE_REQUIRES_AUTH=$2" -e "CASE_ENV_VALUE=$3" \
    php:8.3-cli-alpine php -r '
      try {
          require "/plugin.php";
      } catch (\Error $e) {
          // expected: pocketmine\plugin\PluginBase does not exist in this
          // bare image, and DevEnvGate is declared before Main hits it.
      }
      if (!class_exists("riftal\\dev\\bots\\DevEnvGate")) {
          fwrite(STDERR, "DevEnvGate never got declared\n");
          exit(2);
      }
      $envValue = getenv("CASE_ENV_VALUE");
      $envValue = ($envValue === false || $envValue === "") ? null : $envValue;
      $result = \riftal\dev\bots\DevEnvGate::shouldAdmit(
          getenv("CASE_REQUESTED") === "true",
          getenv("CASE_REQUIRES_AUTH") === "true",
          $envValue
      );
      echo $result ? "admit" : "refuse";
    '
}

section "a genuine dev stack still admits: flag on, xbox-auth off, RIFTAL_DEV_ENV=1"
result="$(gate true false 1)"
[ "$result" = "admit" ] && pass "dev-shaped config admits" \
  || fail "expected admit, got '$result'"

section "the flag and xbox-auth off alone, RIFTAL_DEV_ENV unset, refuses"
# This is riftal-infra#113 itself: the exact shape a real downstream reaches
# once every proxied instance runs xbox-auth=false, with the flag left on by
# a copy-pasted compose file. Flag-on and auth-off alone describe production
# just as well as a dev stack, so the gate needs the explicit env signal too.
result="$(gate true false "")"
[ "$result" = "refuse" ] && pass "production-shaped config (auth off, env unset) refuses" \
  || fail "expected refuse, got '$result'"

section "a near-miss env value refuses, not just an unset one"
result="$(gate true false true)"
[ "$result" = "refuse" ] && pass "RIFTAL_DEV_ENV=true (not the exact string '1') refuses" \
  || fail "expected refuse, got '$result'"

section "xbox-auth on still refuses even with everything else dev-shaped"
result="$(gate true true 1)"
[ "$result" = "refuse" ] && pass "xbox-auth on refuses regardless of RIFTAL_DEV_ENV" \
  || fail "expected refuse, got '$result'"

section "the flag off refuses regardless of the other two signals"
result="$(gate false false 1)"
[ "$result" = "refuse" ] && pass "riftal-dev-bots off refuses even in an otherwise dev-shaped config" \
  || fail "expected refuse, got '$result'"

section "isDevEnvironment is exact-match, not a truthy coercion"
result="$(gate true false 01)"
[ "$result" = "refuse" ] && pass "RIFTAL_DEV_ENV=01 refuses, only the exact string '1' admits" \
  || fail "expected refuse, got '$result'"

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
printf 'all %s assertions passed: dev-shaped config admits, production-shaped config (the vacuous-gate case #113 describes) refuses.\n' "$PASSES"
