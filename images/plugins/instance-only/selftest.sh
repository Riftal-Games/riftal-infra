#!/usr/bin/env bash
# Self-test for the RiftalMines mount in images/compose.yaml (riftal-infra#213).
#
# Static on purpose: it reads the compose model docker compose resolves and a
# config rendered into a scratch directory, and starts no container, so it
# needs neither the dev stack nor a built RiftalMines.phar.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$DIR/../../compose.yaml"
SPEC="$DIR/../../../designer/specs/lumber.json"
command -v jq >/dev/null || { printf '::error::jq is required\n'; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'MYSQL_ROOT_PASSWORD=x\nINSTANCE_ID=a\nINSTANCE_B_ID=b\n' > "$work/env"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=11
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

model() { docker compose -f "$1" --env-file "$work/env" config --format json; }

# $1 compose model, $2 service, $3 mount target, $4 host file name
mounts_ro() {
  jq -e --arg s "$2" --arg t "$3" --arg f "instance-only/$4" \
    '[.services[$s].volumes[] | select(.target == $t and .read_only == true
      and (.source | endswith($f)))] | length == 1' <<<"$1" >/dev/null
}

# Services other than `instance` that mount anything from instance-only/ or
# onto a RiftalMines path.
leaks() {
  jq -r '.services | to_entries[] | select(.key != "instance")
    | select(any(.value.volumes[]?; (.source // "" | test("instance-only"))
      or (.target | test("RiftalMines")))) | .key' <<<"$1"
}

printf '\n== the mount lands on `instance` and nowhere else\n'
real="$(model "$COMPOSE")"
check "instance mounts the phar read-only" \
  'mounts_ro "$real" instance /plugins/RiftalMines.phar RiftalMines.phar'
check "instance mounts the rendered config read-only over the bundled default" \
  'mounts_ro "$real" instance /data/plugin_data/RiftalMines/config.yml RiftalMines.config.yml'
check "no other service mounts RiftalMines" '[ -z "$(leaks "$real")" ]'

# The same compose file with the phar line copied onto instance-b, so the
# check above is known to catch the leak it exists for.
sed '/- riftal-world-b:\/data/a\      - ./plugins/instance-only/RiftalMines.phar:/plugins/RiftalMines.phar:ro' \
  "$COMPOSE" > "$work/compose.yaml"
check "a copy mounting it on instance-b is caught" \
  '[ "$(leaks "$(model "$work/compose.yaml")")" = "instance-b" ]'

printf '\n== the rendered config points at this stack\n'
cp "$DIR/render-config.sh" "$DIR/RiftalMines.config.yml.template" "$work/"
check "rendering refuses an unset password and writes nothing" \
  '! env -u MYSQL_ROOT_PASSWORD bash "$work/render-config.sh" 2>/dev/null && [ ! -e "$work/RiftalMines.config.yml" ]'

# Base64 output, a common way to generate the password, carries / and +.
password='a/b+c&d='
check "a password holding / + & renders" \
  'MYSQL_ROOT_PASSWORD="$password" bash "$work/render-config.sh"'
check "a password that would break the YAML string is refused" \
  '! MYSQL_ROOT_PASSWORD="a\"b" bash "$work/render-config.sh" 2>/dev/null'
rendered="$work/RiftalMines.config.yml"
db() { sed -n "s/^  $1: \"\(.*\)\"\$/\1/p" "$rendered"; }
check "the password renders verbatim and no placeholder is left" \
  '[ "$(db password)" = "$password" ] && ! grep -q __ "$rendered"'
check "the host is the compose mysql service" \
  '[ "$(db host)" = mysql ] && jq -e ".services.mysql" <<<"$real" >/dev/null'
check "the schema is the one compose creates" \
  '[ "$(db schema)" = "$(jq -r .services.mysql.environment.MYSQL_DATABASE <<<"$real")" ]'
check "the registered world is the lumber spec's world" \
  'grep -q "^  $(jq -r .world "$SPEC"): \"worlds/$(jq -r .world "$SPEC").json\"\$" "$rendered"'

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
