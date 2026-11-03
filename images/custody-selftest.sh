#!/usr/bin/env bash
# Self-test for RiftalCustody on every instance (riftal-infra#519, ADR 013
# unit 5): loads-check.sh, plugins/require-custody.sh, the compose wiring that
# runs it, and the softdepend header on every script plugin both instances
# load. Starts no container and needs no built RiftalCustody.phar; the fixture
# log lines are copied from real boots of the pinned core image.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$DIR/compose.yaml"
command -v jq >/dev/null || { printf '::error::jq is required\n'; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'MYSQL_ROOT_PASSWORD=x\nINSTANCE_ID=a\nINSTANCE_B_ID=b\n' > "$work/env"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=12
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

printf '\n== loads-check.sh reads the LOADS verdict and P13 from a boot log\n'
custody='[03:23:41.780] [Server thread/INFO]: Enabling RiftalCustody v0.1.0'
world='[03:23:41.921] [Server thread/INFO]: Preparing world "mine_a"'
bots='[03:23:41.969] [Server thread/INFO]: Enabling RiftalDevBots v0.2.1'
done_line='[03:23:44.281] [Server thread/INFO]: Done (3.109s)! For help, type "help" or "?"'
warning='[03:23:41.204] [Server thread/WARNING]: Online mode is disabled.'
error='[03:23:57.180] [Server thread/ERROR]: [RiftalCustody] disabling RiftalDevBots, still enabled when RiftalCustody disabled'
# Writes its arguments, one per line, as the log and runs the check on it.
loads() { printf '%s\n' "$@" > "$work/boot.log"; bash "$DIR/loads-check.sh" "$work/boot.log" > "$work/loads.out"; }
check "custody enabled before the first world, Done reached, a WARNING only: passes" \
  'loads "$warning" "$custody" "$world" "$bots" "$done_line"'
check "custody enabled after the first world is caught, naming both lines" \
  '! loads "$world" "$custody" "$done_line" && grep -q "enabled on line 2, after the first world was prepared on line 1" "$work/loads.out"'
check "a boot that never enabled custody is caught" \
  '! loads "$world" "$bots" "$done_line" && grep -q "RiftalCustody was never enabled" "$work/loads.out"'
check "a line above WARNING is caught" \
  '! loads "$custody" "$world" "$done_line" "$error" && grep -q "1 line(s) logged above WARNING" "$work/loads.out"'
check "a boot that never reached Done is caught" \
  '! loads "$custody" "$world" && grep -q "never reached Done" "$work/loads.out"'

printf '\n== require-custody.sh stops a boot without RiftalCustody.phar\n'
# Runs a copy with /plugins moved under a scratch root. $1 is what to put at
# RiftalCustody.phar: "built", "empty" or "none".
require() {
  local root="$work/require"
  rm -rf "$root"
  mkdir -p "$root/plugins"
  case "$1" in
    built) printf 'phar' > "$root/plugins/RiftalCustody.phar" ;;
    empty) : > "$root/plugins/RiftalCustody.phar" ;;
  esac
  sed "s#/plugins#$root/plugins#g" "$DIR/plugins/require-custody.sh" > "$root/require.sh"
  bash "$root/require.sh" printf '%s|' a "b c" > "$root/out" 2>&1
}
r="$work/require/out"
check "with the phar built, the start command runs with its arguments intact" \
  'require built && [ "$(cat "$r")" = "a|b c|" ]'
check "without the phar, the boot stops before the start command, naming the path" \
  '! require none && ! grep -q "a|" "$r" && grep -q "plugins/RiftalCustody.phar is not built" "$r"'
check "an empty phar is refused" '! require empty && ! grep -q "a|" "$r"'

printf '\n== every instance in compose.yaml runs require-custody.sh first\n'
model() { docker compose -f "$1" --env-file "$work/env" config --format json; }
# PocketMine services whose command does not hand over to require-custody.sh
# ahead of the script that starts PocketMine.
unguarded() {
  jq -r '.services | to_entries[] | select(.value.image | test("pocketmine"))
    | select((.value.command | index(["bash", "/plugins/require-custody.sh"])) as $at
      | $at == null or $at + 2 >= (.value.command | length))
    | .key' <<<"$1"
}
real="$(model "$COMPOSE")"
check "instance and instance-b both run it before their start script" \
  '[ -z "$(unguarded "$real")" ] &&
    [ "$(jq -r ".services | to_entries[] | select(.value.image | test(\"pocketmine\")) | .key" <<<"$real" | sort | tr "\n" " ")" = "instance instance-b " ]'
sed 's#"bash", "/plugins/require-custody.sh", "bash", "/plugins/instance-b/start.sh"#"bash", "/plugins/instance-b/start.sh"#' "$COMPOSE" > "$work/compose.yaml"
check "an instance that skips it is caught" '[ "$(unguarded "$(model "$work/compose.yaml")")" = instance-b ]'

printf '\n== every script plugin both instances load softdepends on RiftalCustody\n'
# Script plugins at the top of $1 whose header, the first /** */ block as core's
# ScriptPluginLoader reads it, has no `@softdepend RiftalCustody` line.
unsoft() {
  local f
  for f in "$1"/*.php; do
    sed -n '\#/\*\*#,\#\*/#p;\#\*/#q' "$f" | grep -qE '^[[:space:]]*\*?[[:space:]]*@softdepend[[:space:]]+RiftalCustody[[:space:]]*$' ||
      basename "$f"
  done
}
check "RiftalDevBots.php carries the header, and no script plugin lacks it" \
  'ls "$DIR/plugins"/*.php | grep -q RiftalDevBots.php && [ -z "$(unsoft "$DIR/plugins")" ]'
mkdir -p "$work/scripts"
sed '/@softdepend RiftalCustody/d' "$DIR/plugins/RiftalDevBots.php" > "$work/scripts/RiftalDevBots.php"
check "a header without it is caught" '[ "$(unsoft "$work/scripts")" = RiftalDevBots.php ]'

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
printf 'all %s assertions passed\n' "$PASSES"
