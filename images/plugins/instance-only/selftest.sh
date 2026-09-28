#!/usr/bin/env bash
# Self-test for how images/compose.yaml loads RiftalMines (riftal-infra#213)
# and for start-instance.sh, the script that loads it. Also pins crash
# auto-report off on every PocketMine service, designer/stack's included, and
# covers deliver-world-index.sh and the index mount both instances boot with
# (riftal-infra#293).
#
# It reads the compose model docker compose resolves, renders the config into
# a scratch directory, and runs start-instance.sh there with php and wget
# stubbed. It starts no container, so it needs neither the dev stack nor a
# built RiftalMines.phar.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$DIR/../../compose.yaml"
SPEC="$DIR/../../../designer/specs/lumber.json"
command -v jq >/dev/null || { printf '::error::jq is required\n'; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'MYSQL_ROOT_PASSWORD=x\nINSTANCE_ID=a\nINSTANCE_B_ID=b\nDESIGNBRIDGE_TOKEN=t\n' > "$work/env"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=40
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
  'jq -e ".services.instance | .command[-2:] == [\"bash\", \"/plugins/instance-only/start-instance.sh\"]
    and any(.volumes[]; .target == \"/plugins\" and (.source | endswith(\"images/plugins\")))" \
    <<<"$real" >/dev/null'
check "no service mounts anything inside /plugins or /data" '[ -z "$(nested "$real")" ]'
check "a file mounted inside /data is caught" \
  '[ "$(nested "$(edited "/- riftal-world:\/data/a\      - ./x.yml:/data/plugin_data/x.yml:ro")")" = /data/plugin_data/x.yml ]'
check "no other service loads RiftalMines" '[ -z "$(leaks "$real")" ]'
check "a copy mounting instance-only on instance-b is caught" \
  '[ "$(leaks "$(edited "/- riftal-world-b:\/data/a\      - ./plugins/instance-only:/i:ro")")" = instance-b ]'

printf '\n== no PocketMine service uploads a crash dump (riftal-infra#232)\n'
DESIGNER="$DIR/../../../designer/stack/compose.yaml"
# Services running a PocketMine image whose POCKETMINE_ARGS does not set
# auto-report.enabled to exactly one 0. ServerConfigGroup::getPropertyBool()
# casts the flag's string, so "false", "no" or a repeat all read as true.
uploaders() {
  jq -r '.services | to_entries[] | select(.value.image | test("pocketmine"))
    | select([.value.environment.POCKETMINE_ARGS // "" | splits("\\s+")
      | select(startswith("--auto-report.enabled"))] != ["--auto-report.enabled=0"])
    | .key' <<<"$1"
}
designer="$(model "$DESIGNER")"
check "instance, instance-b and designer are the PocketMine services checked" \
  '[ "$(jq -r ".services | to_entries[] | select(.value.image | test(\"pocketmine\")) | .key" \
    <<<"$real$designer" | sort | tr "\n" " ")" = "designer instance instance-b " ]'
check "every PocketMine service passes --auto-report.enabled=0" \
  '[ -z "$(uploaders "$real")" ] && [ -z "$(uploaders "$designer")" ]'
check "--auto-report.enabled=false, which PocketMine reads as true, is caught" \
  '[ "$(uploaders "$(edited "/instance-b:/,\$s/--auto-report.enabled=0/--auto-report.enabled=false/")")" = instance-b ]'
check "a service without the flag is caught" \
  '[ "$(uploaders "$(edited "0,/--auto-report.enabled=0/{/--auto-report.enabled=0/d}")")" = instance ]'

printf '\n== the rendered config points at this stack\n'
cp "$DIR/render-config.sh" "$DIR/RiftalMines.config.yml.template" "$work/"
rendered="$work/RiftalMines.config.yml"
check "rendering refuses an unset password and writes nothing" \
  '! env -u MYSQL_ROOT_PASSWORD bash "$work/render-config.sh" "$rendered" 2>/dev/null && [ ! -e "$rendered" ]'

# Base64 output, a common way to generate the password, carries / and +.
password='a/b+c&d='
check "a password holding / + & renders" \
  'MYSQL_ROOT_PASSWORD="$password" bash "$work/render-config.sh" "$rendered"'
check "a password that would break the YAML string is refused" \
  '! MYSQL_ROOT_PASSWORD="a\"b" bash "$work/render-config.sh" "$rendered" 2>/dev/null'
check "a password holding a backslash is refused" \
  '! MYSQL_ROOT_PASSWORD="a\\b" bash "$work/render-config.sh" "$rendered" 2>/dev/null'
db() { sed -n "s/^  $1: \"\(.*\)\"\$/\1/p" "${2:-$rendered}"; }
check "the password renders verbatim and no placeholder is left" \
  '[ "$(db password)" = "$password" ] && ! grep -q __ "$rendered"'
check "the host is the compose mysql service" \
  '[ "$(db host)" = mysql ] && jq -e ".services.mysql" <<<"$real" >/dev/null'
check "the schema is the one compose creates" \
  '[ "$(db schema)" = "$(jq -r .services.mysql.environment.MYSQL_DATABASE <<<"$real")" ]'
check "the registered world is the lumber spec's world" \
  'grep -q "^  $(jq -r .world "$SPEC"): \"worlds/$(jq -r .world "$SPEC").json\"\$" "$rendered"'
check "instance gets mysql's password and instance-b gets none" \
  'jq -e ".services | .instance.environment.MYSQL_ROOT_PASSWORD == .mysql.environment.MYSQL_ROOT_PASSWORD
    and .instance.environment.MYSQL_ROOT_PASSWORD != null
    and .[\"instance-b\"].environment.MYSQL_ROOT_PASSWORD == null" <<<"$real" >/dev/null'

printf '\n== start-instance.sh keeps what start-pocketmine does for instance-b\n'
# Runs a copy of start-instance.sh with its absolute paths moved under a
# scratch root and php and wget stubbed, so nothing boots and nothing is
# fetched. $1 is the uid the ownership check treats as pocketmine; the rest
# are environment assignments. The shared /plugins starts with Cached.phar.
# With MINES set, RiftalMines.phar is built and a config rendered by hand
# with a password no stack has sits next to it.
boot() {
  local owner="$1" root="$work/boot"
  shift
  rm -rf "$root"
  mkdir -p "$root/plugins" "$root/data" "$root/pm" "$root/bin"
  : > "$root/plugins/Cached.phar"
  cp "$DIR/render-config.sh" "$DIR/RiftalMines.config.yml.template" "$root/"
  if [ -n "${MINES:-}" ]; then
    : > "$root/RiftalMines.phar"
    MYSQL_ROOT_PASSWORD=stale bash "$root/render-config.sh" "$root/RiftalMines.config.yml"
  fi
  sed -e "s#/plugins#$root/plugins#g; s#/data#$root/data#g" \
    -e "s#/opt/pocketmine#$root/pm#g; s#-user pocketmine#-user $owner#g" \
    "$DIR/start-instance.sh" > "$root/start-instance.sh"
  cat > "$root/bin/php" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$root/args"
for a; do case "\$a" in --plugins=*) ls "\${a#--plugins=}" > "$root/roster" ;; esac; done
EOF
  cat > "$root/bin/wget" <<EOF
#!/bin/bash
printf '%s\n' "\$3" >> "$root/fetched"
: > "\$2"
EOF
  chmod +x "$root/bin/php" "$root/bin/wget"
  env -i HOME="$work" PATH="$root/bin:$PATH" "$@" \
    bash "$root/start-instance.sh" > "$root/out" 2>&1 < /dev/null \
    && [ -s "$root/args" ]
}
me="$(id -u)"
b="$work/boot"
check "POCKETMINE_ANSI=1 passes --enable-ansi" \
  'boot "$me" POCKETMINE_ANSI=1 && grep -qx -- --enable-ansi "$b/args"'
check "POCKETMINE_ANSI=0, and auto off a TTY, leave ANSI off" \
  'boot "$me" POCKETMINE_ANSI=0 && ! grep -q ansi "$b/args" && boot "$me" && ! grep -q ansi "$b/args"'
check "POCKETMINE_PLUGINS fetches each missing plugin at its version into the roster" \
  'boot "$me" POCKETMINE_PLUGINS="Foo:1.2 Bar Cached" &&
    [ "$(cat "$b/fetched")" = "$(printf "%s\n" https://poggit.pmmp.io/get/Foo/1.2 https://poggit.pmmp.io/get/Bar/)" ] &&
    [ "$(cat "$b/roster")" = "$(printf "%s\n" Bar.phar Cached.phar Foo.phar)" ]'
check "a POCKETMINE_PLUGINS spread over two lines fetches from both" \
  'boot "$me" POCKETMINE_PLUGINS="$(printf "Foo\nBar")" &&
    [ "$(cat "$b/roster")" = "$(printf "%s\n" Bar.phar Cached.phar Foo.phar)" ]'
check "instance's POCKETMINE_ARGS reaches php with auto-report off" \
  'boot "$me" POCKETMINE_ARGS="$(jq -r .services.instance.environment.POCKETMINE_ARGS <<<"$real")" &&
    grep -qx -- --auto-report.enabled=0 "$b/args"'
check "an unset POCKETMINE_ARGS boots, as it does under start-pocketmine" \
  'boot "$me" && ! grep -q unbound "$b/out"'
check "POCKETMINE_PLUGINS writes nothing into the shared /plugins" \
  'boot "$me" POCKETMINE_PLUGINS="Foo Bar" && [ "$(ls "$b/plugins")" = Cached.phar ]'
check "a file in /plugins not owned by pocketmine is warned about" \
  'boot "$((me + 1))" && grep -q "=== WARNING ===" "$b/out" && grep -q "Cached.phar" "$b/out"'
check "no ownership warning when pocketmine owns everything" \
  'boot "$me" && ! grep -q WARNING "$b/out"'

printf '\n== RiftalMines gets the password its container boots with (riftal-infra#266)\n'
mines_config="$b/data/plugin_data/RiftalMines/config.yml"
check "the config on the volume carries MYSQL_ROOT_PASSWORD, not the stale rendered file" \
  'MINES=1 boot "$me" MYSQL_ROOT_PASSWORD="$password" &&
    [ "$(db password "$mines_config")" = "$password" ] && grep -qx RiftalMines.phar "$b/roster"'
check "an unset MYSQL_ROOT_PASSWORD stops the boot before php, naming it" \
  '! MINES=1 boot "$me" && [ ! -e "$b/args" ] && grep -q "MYSQL_ROOT_PASSWORD is not set" "$b/out"'

printf '\n== the world index reaches every plugin that reads it (riftal-infra#293)\n'
INDEX="$DIR/../../../designer/world_index.json"
# PocketMine services in images/compose.yaml that do not run the delivery
# script first or do not get the designer index mounted read-only for it.
undelivered() {
  jq -r '.services | to_entries[] | select(.value.image | test("pocketmine"))
    | select((.value.command[0:2] != ["bash", "/plugins/deliver-world-index.sh"])
      or (any(.value.volumes[]?; .target == "/etc/riftal/world_index.json"
        and (.source | endswith("designer/world_index.json")) and .read_only) | not))
    | .key' <<<"$1"
}
check "instance and instance-b both run the delivery with the designer index mounted" \
  '[ -z "$(undelivered "$real")" ] &&
    [ "$(jq -c ".services.instance.command[2:]" <<<"$real")" = "[\"bash\",\"/plugins/instance-only/start-instance.sh\"]" ] &&
    [ "$(jq -c ".services[\"instance-b\"].command[2:]" <<<"$real")" = "[\"start-pocketmine\"]" ]'
check "an instance without the index mounted is caught" \
  '[ "$(undelivered "$(edited "0,/world_index.json:ro/{/world_index.json:ro/d}")")" = instance ]'

# Runs a copy of deliver-world-index.sh with /etc/riftal and /data moved under
# a scratch root; $1 is the index to mount ("" for none), the rest the command
# it hands over to. A stale index already sits in RiftalRanks' folder.
deliver() {
  local src="$1" root="$work/deliver"
  shift
  rm -rf "$root"
  mkdir -p "$root/etc" "$root/data/plugin_data/RiftalRanks"
  printf '{}' > "$root/data/plugin_data/RiftalRanks/world_index.json"
  if [ -n "$src" ]; then cp "$src" "$root/etc/world_index.json"; fi
  sed -e "s#/etc/riftal#$root/etc#g; s#/data#$root/data#g" \
    "$DIR/../deliver-world-index.sh" > "$root/deliver.sh"
  bash "$root/deliver.sh" "$@" > "$root/out" 2>&1
}
d="$work/deliver/data/plugin_data"
check "RiftalRanks, RiftalRiots, RiftalEconomy and RiftalMines each get the designer index byte for byte, stale copy replaced" \
  'deliver "$INDEX" true && cmp -s "$INDEX" "$d/RiftalRanks/world_index.json" &&
    cmp -s "$INDEX" "$d/RiftalRiots/world_index.json" &&
    cmp -s "$INDEX" "$d/RiftalEconomy/world_index.json" &&
    cmp -s "$INDEX" "$d/RiftalMines/world_index.json"'
check "the copies belong to the uid the script runs as, uid 1000 in the image" \
  'deliver "$INDEX" true && [ -f "$d/RiftalRiots/world_index.json" ] && [ -z "$(find "$d" ! -user "$me")" ]'
check "the start command runs after delivery with its arguments intact" \
  'deliver "$INDEX" printf "%s|" a "b c" && [ "$(cat "$work/deliver/out")" = "a|b c|" ]'
check "a missing index stops the boot before the start command, naming the path" \
  '! deliver "" printf started && ! grep -q started "$work/deliver/out" &&
    grep -q "etc/world_index.json" "$work/deliver/out"'

printf '\n== the template keeps the plugin'"'"'s shipped tuning (riftal-infra#262)\n'
# The plugin throws on enable when any of these keys is missing, so the
# template has to carry them. CI checks out this repository alone and holds no
# token for the private riftal-game, so there the comparison is reported as
# skipped rather than passed.
SHIPPED="${RIFTAL_GAME_DIR:-$DIR/../../../../riftal-game}/mines/resources/config.yml"
TEMPLATE="$DIR/RiftalMines.config.yml.template"
SKIPPED=0
# Each assertion here is counted as skipped rather than dropped when the
# shipped file is absent, so the assertion count still sees one deleted.
drift() { if [ -f "$SHIPPED" ]; then check "$1" "$2"; else SKIPPED=$((SKIPPED + 1)); fi; }
# Every top-level key, whether it holds a scalar or opens a section.
keys() { grep -oE '^[^[:space:]#-][^:]*:' "$1" | sort -u; }
# Top-level keys holding a scalar. The database and worlds sections hold
# none, so the values the template overrides on purpose stay out of it.
tuning() { grep -E '^[^[:space:]#-][^:]*:[[:space:]]*[^[:space:]#]' "$1" | sed 's/[[:space:]]*$//' | sort; }
# Top-level keys in the shipped file $1 that the template lacks.
missing() { comm -23 <(keys "$1") <(keys "$TEMPLATE"); }
mutated="$work/shipped.yml"
drift "every scalar key in riftal-game's mines config.yml matches the template" \
  '[ -n "$(tuning "$SHIPPED")" ] && [ "$(tuning "$SHIPPED")" = "$(tuning "$TEMPLATE")" ]'
drift "every top-level key in riftal-game's mines config.yml, section or scalar, is in the template" \
  '[ -n "$(keys "$SHIPPED")" ] && [ -z "$(missing "$SHIPPED")" ]'
drift "a shipped value the template does not carry is caught" \
  'sed "s/^refill_blocks_per_tick:.*/refill_blocks_per_tick: 1/" "$SHIPPED" > "$mutated" &&
    [ "$(tuning "$mutated")" != "$(tuning "$TEMPLATE")" ]'
drift "a shipped scalar whose key holds a digit or hyphen is caught" \
  '{ cat "$SHIPPED"; printf "refill_v2-budget: 3\n"; } > "$mutated" &&
    [ "$(tuning "$mutated")" != "$(tuning "$TEMPLATE")" ]'
drift "a shipped section the template lacks is caught" \
  '{ cat "$SHIPPED"; printf "messages:\n  reset: x\n"; } > "$mutated" &&
    [ "$(missing "$mutated")" = "messages:" ]'
if [ "$SKIPPED" -ne 0 ]; then
  printf '::warning::%s assertions skipped: no riftal-game mines config at %s; set RIFTAL_GAME_DIR\n' \
    "$SKIPPED" "$SHIPPED"
fi

printf '\n'
ran=$((PASSES + FAILURES + SKIPPED))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
if [ "$SKIPPED" -ne 0 ]; then
  printf '%s assertions passed, %s skipped\n' "$PASSES" "$SKIPPED"
  exit 0
fi
printf 'all %s assertions passed\n' "$PASSES"
