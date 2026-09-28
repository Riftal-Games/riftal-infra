#!/usr/bin/env bash
# Self-test for how images/compose.yaml loads RiftalMines (riftal-infra#213).
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
EXPECTED_ASSERTIONS=13
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

model() { docker compose -f "$1" --env-file "$work/env" config --format json; }

# $1 sed script applied to the real compose file; prints the resulting compose model
edited() { sed "$1" "$COMPOSE" > "$work/compose.yaml"; model "$work/compose.yaml"; }

# Docker creates a missing mountpoint as root. Inside the ./plugins bind that
# is a root-owned stray in the host directory instance-b loads from; inside
# the /data volume it is a plugin_data PocketMine cannot write to.
nested() {
  jq -r '.services[] | .volumes[]? | .target
    | select(test("^/(plugins|data)/"))' <<<"$1"
}

# Services other than `instance` that run its start script or mount anything
# from instance-only/.
leaks() {
  jq -r '.services | to_entries[] | select(.key != "instance")
    | select((.value.command // [] | tostring | test("start-instance"))
      or any(.value.volumes[]?; .source // "" | test("instance-only")))
    | .key' <<<"$1"
}

printf '\n== RiftalMines loads on `instance` and nowhere else\n'
real="$(model "$COMPOSE")"
check "instance runs start-instance.sh from its ./plugins bind" \
  'jq -e ".services.instance | .command == [\"bash\", \"/plugins/instance-only/start-instance.sh\"]
    and any(.volumes[]; .target == \"/plugins\" and (.source | endswith(\"images/plugins\")))" \
    <<<"$real" >/dev/null'
check "no service mounts anything inside /plugins or /data" '[ -z "$(nested "$real")" ]'
check "a file mounted inside /data is caught" \
  '[ "$(nested "$(edited "/- riftal-world:\/data/a\      - ./x.yml:/data/plugin_data/x.yml:ro")")" = /data/plugin_data/x.yml ]'
check "no other service loads RiftalMines" '[ -z "$(leaks "$real")" ]'
check "a copy mounting instance-only on instance-b is caught" \
  '[ "$(leaks "$(edited "/- riftal-world-b:\/data/a\      - ./plugins/instance-only:/i:ro")")" = instance-b ]'

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
check "a password holding a backslash is refused" \
  '! MYSQL_ROOT_PASSWORD="a\\b" bash "$work/render-config.sh" 2>/dev/null'
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
