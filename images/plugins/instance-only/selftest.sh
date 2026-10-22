#!/usr/bin/env bash
# Self-test for how images/compose.yaml loads RiftalMines (riftal-infra#213)
# and RiftalAccounts (riftal-infra#465), RiftalRanks (riftal-infra#558) and
# RiftalEconomy (riftal-infra#887), and for start-instance.sh and
# require-accounts.sh, the scripts that load them. Also pins crash
# auto-report off on every PocketMine service, designer/stack's included, and
# covers deliver-world-index.sh and the index mount both instances boot with
# (riftal-infra#293), and the memory and CPU limits on mysql and both
# instances (riftal-infra#460).
#
# It reads the compose model docker compose resolves, renders the config into
# a scratch directory, and runs start-instance.sh there with php and wget
# stubbed. It also covers link-replaced.sh, which it runs against scratch
# fixtures in a throwaway php:8.3-cli-alpine container, so it needs Docker and
# that image, but neither the dev stack nor a built RiftalMines.phar,
# RiftalRanks.phar or RiftalEconomy.phar.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$DIR/../../compose.yaml"
SPEC="$DIR/../../../designer/specs/lumber.json"
command -v jq >/dev/null || { printf '::error::jq is required\n'; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ACCOUNTS_PW=selftestAccountsPassword01
RANKS_PW=selftestRanksPassword0001
ECONOMY_PW=selftestEconomyPassword01
MINES_PW=selftestMinesPassword0001
printf 'MYSQL_ROOT_PASSWORD=x\nINSTANCE_ID=a\nINSTANCE_B_ID=b\nDESIGNBRIDGE_TOKEN=t\nRIFTAL_DB_PASSWORD_ACCOUNTS=%s\nRIFTAL_DB_PASSWORD_RANKS=%s\nRIFTAL_DB_PASSWORD_ECONOMY=%s\nRIFTAL_DB_PASSWORD_MINES=%s\n' \
  "$ACCOUNTS_PW" "$RANKS_PW" "$ECONOMY_PW" "$MINES_PW" > "$work/env"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=86
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

printf '\n== mysql and both instances run bounded (riftal-infra#460)\n'
# Services whose resolved mem_limit, in bytes, and cpus are not 1G and 1 for
# mysql and 2G and 2 for each instance. `docker compose config` accepts a file
# with a limit deleted, so only this catches one going missing.
unbounded() {
  jq -r '.services as $s
    | {"mysql": ["1073741824", "1"], "instance": ["2147483648", "2"], "instance-b": ["2147483648", "2"]}
    | to_entries[]
    | select([($s[.key].mem_limit | tostring), ($s[.key].cpus | tostring)] != .value)
    | .key' <<<"$1"
}
check "mysql resolves 1073741824 bytes and 1 CPU, instance and instance-b 2147483648 and 2" \
  '[ -z "$(unbounded "$real")" ]'
check "instance-b without mem_limit is caught" \
  '[ "$(unbounded "$(edited "/^  instance-b:/,\$ {/mem_limit/d}")")" = instance-b ]'
check "instance with cpus 4 is caught" \
  '[ "$(unbounded "$(edited "0,/cpus: 2/s/cpus: 2/cpus: 4/")")" = instance ]'

printf '\n== the rendered config points at this stack as the mines login (ADR 008)\n'
cp "$DIR/render-config.sh" "$DIR/RiftalMines.config.yml.template" "$work/"
rendered="$work/RiftalMines.config.yml"
TEMPLATE="$DIR/RiftalMines.config.yml.template"
check "rendering needs no password in the environment and writes the template as is" \
  'env -i PATH="$PATH" bash "$work/render-config.sh" "$rendered" && cmp -s "$TEMPLATE" "$rendered"'
db() { sed -n "s/^  $1: \"\(.*\)\"\$/\1/p" "${2:-$rendered}"; }
check "the rendered config logs in as the mines login, never root" \
  '[ "$(db username)" = mines ] && [ "$(grep -c "^ *username:" "$rendered")" = 1 ]'
check "the rendered config holds an empty password and no placeholder" \
  'grep -qx "  password: \"\"" "$rendered" && [ "$(grep -c "^ *password:" "$rendered")" = 1 ] && ! grep -q __ "$rendered"'
check "the host is the compose mysql service" \
  '[ "$(db host)" = mysql ] && jq -e ".services.mysql" <<<"$real" >/dev/null'
check "the schema is the one compose creates" \
  '[ "$(db schema)" = "$(jq -r .services.mysql.environment.MYSQL_DATABASE <<<"$real")" ]'
check "the registered world is the lumber spec's world" \
  'grep -q "^  $(jq -r .world "$SPEC"): \"worlds/$(jq -r .world "$SPEC").json\"\$" "$rendered"'
check "instance gets RIFTAL_DB_PASSWORD_MINES and never the root password, instance-b neither" \
  'jq -e ".services | .instance.environment.RIFTAL_DB_PASSWORD_MINES == \"$MINES_PW\"
    and .instance.environment.MYSQL_ROOT_PASSWORD == null
    and .[\"instance-b\"].environment.RIFTAL_DB_PASSWORD_MINES == null
    and .[\"instance-b\"].environment.MYSQL_ROOT_PASSWORD == null" <<<"$real" >/dev/null'

printf '\n== start-instance.sh keeps what start-pocketmine does\n'
# Runs a copy of start-instance.sh with its absolute paths moved under a
# scratch root and php and wget stubbed, so nothing boots and nothing is
# fetched. $1 is the uid the ownership check treats as pocketmine; the rest
# are environment assignments. The shared /plugins starts with Cached.phar.
# With MINES set, RiftalMines.phar is built, contracts.phar sits at the top of
# /plugins as on the real stack, a config rendered by hand sits next to it, and
# the volume holds one an earlier boot rendered as root. With RANKS set,
# RiftalRanks.phar is built, and with ECONOMY set, RiftalEconomy.phar.
ROOT_PW=rootPasswordFromAnEarlierBoot
boot() {
  local owner="$1" root="$work/boot"
  shift
  rm -rf "$root"
  mkdir -p "$root/plugins" "$root/data" "$root/pm" "$root/bin"
  : > "$root/plugins/Cached.phar"
  cp "$DIR/render-config.sh" "$DIR/RiftalMines.config.yml.template" "$DIR/RiftalRanks.config.yml" \
    "$DIR/RiftalEconomy.config.yml" "$root/"
  if [ -n "${MINES:-}" ]; then
    : > "$root/RiftalMines.phar"
    : > "$root/plugins/contracts.phar"
    mkdir -p "$root/data/plugin_data/RiftalMines"
    printf 'database:\n  username: "root"\n  password: "%s"\n' "$ROOT_PW" |
      tee "$root/RiftalMines.config.yml" > "$root/data/plugin_data/RiftalMines/config.yml"
  fi
  if [ -n "${RANKS:-}" ]; then
    : > "$root/RiftalRanks.phar"
  fi
  if [ -n "${ECONOMY:-}" ]; then
    : > "$root/RiftalEconomy.phar"
  fi
  # A source folder DevTools would load, and two it would refuse.
  if [ -n "${FOLDERS:-}" ]; then
    mkdir -p "$root/plugins/Folder/src" "$root/plugins/NoSrc" "$root/plugins/NoManifest/src"
    : > "$root/plugins/Folder/plugin.yml"
    : > "$root/plugins/Folder/src/Main.php"
    : > "$root/plugins/NoSrc/plugin.yml"
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
  env -i HOME="$work" PATH="$root/bin:$PATH" TMPDIR="$root" "$@" \
    bash "$root/start-instance.sh" > "$root/out" 2>&1 < /dev/null \
    && [ -s "$root/args" ]
}
me="$(id -u)"
b="$work/boot"
check "POCKETMINE_ANSI=1 passes --enable-ansi" \
  'boot "$me" POCKETMINE_ANSI=1 && grep -qx -- --enable-ansi "$b/args"'
check "POCKETMINE_ANSI=0, and auto off a TTY, leave ANSI off" \
  'boot "$me" POCKETMINE_ANSI=0 && ! grep -q ansi "$b/args" && boot "$me" && ! grep -q ansi "$b/args"'
# The boot helper rewrites every /plugins in the script, the message's included,
# so the match stops before it.
check "a non-empty POCKETMINE_PLUGINS stops the boot before php, fetching nothing and saying where plugins come from" \
  '! boot "$me" POCKETMINE_PLUGINS="Foo:1.2 Bar" && [ ! -e "$b/args" ] && [ ! -e "$b/fetched" ] &&
    grep -q "POCKETMINE_PLUGINS is set; plugins come only from the image or " "$b/out"'
check "an unset or empty POCKETMINE_PLUGINS boots, fetching nothing" \
  'boot "$me" && [ ! -e "$b/fetched" ] && boot "$me" POCKETMINE_PLUGINS= && [ ! -e "$b/fetched" ] &&
    [ "$(cat "$b/roster")" = Cached.phar ]'
check "instance's POCKETMINE_ARGS reaches php with auto-report off" \
  'boot "$me" POCKETMINE_ARGS="$(jq -r .services.instance.environment.POCKETMINE_ARGS <<<"$real")" &&
    grep -qx -- --auto-report.enabled=0 "$b/args"'
check "php gets --data at the rewritten /data" \
  'boot "$me" && grep -qx -- "--data=$b/data" "$b/args"'
# The roster is a mktemp -d the script never removes, since exec hands the
# process to php. Made anywhere but under the scratch root, every boot here
# would leave one behind.
check "the roster is made under the scratch root, so no boot leaves one in /tmp" \
  'boot "$me" && roster="$(sed -n "s/^--plugins=//p" "$b/args")" && [[ "$roster" == "$b"/* ]]'
check "an unset POCKETMINE_ARGS boots, as it does under start-pocketmine" \
  'boot "$me" && ! grep -q unbound "$b/out"'
check "a file in /plugins not owned by pocketmine is warned about" \
  'boot "$((me + 1))" && grep -q "=== WARNING ===" "$b/out" && grep -q "Cached.phar" "$b/out"'
check "no ownership warning when pocketmine owns everything" \
  'boot "$me" && ! grep -q WARNING "$b/out"'
check "a source folder at the top of /plugins joins the roster with its src (riftal-infra#274)" \
  'FOLDERS=1 boot "$me" && [ "$(cat "$b/roster")" = "$(printf "%s\n" Cached.phar Folder)" ] &&
    [ -f "$(sed -n "s/^--plugins=//p" "$b/args")/Folder/src/Main.php" ]'
check "a folder without plugin.yml or src, as instance-only is, stays out of the roster" \
  'FOLDERS=1 boot "$me" && ! grep -qE "NoSrc|NoManifest" "$b/roster"'

printf '\n== RiftalMines logs in as mines, its password only in the environment (riftal-infra#246)\n'
mines_config="$b/data/plugin_data/RiftalMines/config.yml"
# Files under the volume holding either password.
leaked() { grep -rlF -e "$MINES_PW" -e "$ROOT_PW" "$b/data" || true; }
check "the template replaces the root config on the volume, not the hand-rendered copy" \
  'MINES=1 boot "$me" RIFTAL_DB_PASSWORD_MINES="$MINES_PW" &&
    cmp -s "$TEMPLATE" "$mines_config" && grep -qx RiftalMines.phar "$b/roster" &&
    grep -qx contracts.phar "$b/roster"'
check "after that boot no file on the volume holds the mines or the root password" \
  'MINES=1 boot "$me" RIFTAL_DB_PASSWORD_MINES="$MINES_PW" && [ -z "$(leaked)" ]'
check "a password left on the volume is caught" \
  'printf "%s\n" "$MINES_PW" > "$b/data/stray" && [ "$(leaked)" = "$b/data/stray" ]'
check "an unset RIFTAL_DB_PASSWORD_MINES stops the boot before php, naming it, root password or not" \
  '! MINES=1 boot "$me" MYSQL_ROOT_PASSWORD="$ROOT_PW" && [ ! -e "$b/args" ] &&
    grep -q "RIFTAL_DB_PASSWORD_MINES is not set" "$b/out"'

printf '\n== RiftalRanks connects as the ranks login, its password only in the environment (riftal-infra#558)\n'
RANKS_CONFIG="$DIR/RiftalRanks.config.yml"
ranks_on_volume="$b/data/plugin_data/RiftalRanks/config.yml"
check "the ranks config names the compose mysql, its schema and the ranks login, with no password" \
  '[ "$(db host "$RANKS_CONFIG")" = mysql ] && [ "$(db username "$RANKS_CONFIG")" = ranks ] &&
    [ "$(db schema "$RANKS_CONFIG")" = "$(jq -r .services.mysql.environment.MYSQL_DATABASE <<<"$real")" ] &&
    grep -qx "  password: \"\"" "$RANKS_CONFIG"'
check "instance gets RIFTAL_DB_PASSWORD_RANKS from images/.env and instance-b gets none" \
  'jq -e ".services | .instance.environment.RIFTAL_DB_PASSWORD_RANKS == \"$RANKS_PW\"
    and .[\"instance-b\"].environment.RIFTAL_DB_PASSWORD_RANKS == null" <<<"$real" >/dev/null'
check "with RiftalRanks.phar built, the tracked config lands on the volume and the phar joins the roster" \
  'RANKS=1 boot "$me" RIFTAL_DB_PASSWORD_RANKS="$RANKS_PW" &&
    cmp -s "$RANKS_CONFIG" "$ranks_on_volume" && grep -qx RiftalRanks.phar "$b/roster"'
check "with RiftalRanks.phar built, an unset RIFTAL_DB_PASSWORD_RANKS stops the boot before php, naming it" \
  '! RANKS=1 boot "$me" && [ ! -e "$b/args" ] && grep -q "RIFTAL_DB_PASSWORD_RANKS is not set" "$b/out"'
check "without RiftalRanks.phar, no ranks config lands and no ranks password is needed" \
  'boot "$me" && [ ! -e "$ranks_on_volume" ] && ! grep -q RiftalRanks "$b/roster"'

printf '\n== RiftalEconomy connects as the economy login, its password only in the environment (riftal-infra#887)\n'
ECONOMY_CONFIG="$DIR/RiftalEconomy.config.yml"
economy_on_volume="$b/data/plugin_data/RiftalEconomy/config.yml"
check "the economy config names the compose mysql, its schema and the economy login, with no password" \
  '[ "$(db host "$ECONOMY_CONFIG")" = mysql ] && [ "$(db username "$ECONOMY_CONFIG")" = economy ] &&
    [ "$(db schema "$ECONOMY_CONFIG")" = "$(jq -r .services.mysql.environment.MYSQL_DATABASE <<<"$real")" ] &&
    grep -qx "  password: \"\"" "$ECONOMY_CONFIG"'
check "instance and instance-b get RIFTAL_DB_PASSWORD_ECONOMY from images/.env (riftal-infra#348)" \
  'jq -e ".services | .instance.environment.RIFTAL_DB_PASSWORD_ECONOMY == \"$ECONOMY_PW\"
    and .[\"instance-b\"].environment.RIFTAL_DB_PASSWORD_ECONOMY == \"$ECONOMY_PW\"" <<<"$real" >/dev/null'
check "with RiftalEconomy.phar built, the tracked config lands on the volume and the phar joins the roster" \
  'ECONOMY=1 boot "$me" RIFTAL_DB_PASSWORD_ECONOMY="$ECONOMY_PW" &&
    cmp -s "$ECONOMY_CONFIG" "$economy_on_volume" && grep -qx RiftalEconomy.phar "$b/roster"'
check "with RiftalEconomy.phar built, an unset RIFTAL_DB_PASSWORD_ECONOMY stops the boot before php, naming it" \
  '! ECONOMY=1 boot "$me" && [ ! -e "$b/args" ] && grep -q "RIFTAL_DB_PASSWORD_ECONOMY is not set" "$b/out"'
check "without RiftalEconomy.phar, no economy config lands and no economy password is needed" \
  'boot "$me" && [ ! -e "$economy_on_volume" ] && ! grep -q RiftalEconomy "$b/roster"'

printf '\n== RiftalAccounts loads on every instance as the accounts login (riftal-infra#465)\n'
ACCOUNTS_CONFIG="$DIR/../RiftalAccounts.config.yml"
check "the accounts config names the compose mysql, its schema and the accounts login, with no password" \
  '[ "$(db host "$ACCOUNTS_CONFIG")" = mysql ] && [ "$(db username "$ACCOUNTS_CONFIG")" = accounts ] &&
    [ "$(db schema "$ACCOUNTS_CONFIG")" = "$(jq -r .services.mysql.environment.MYSQL_DATABASE <<<"$real")" ] &&
    grep -qx "  password: \"\"" "$ACCOUNTS_CONFIG"'
# Holds when instance and instance-b get the password from images/.env and no
# other service gets it.
password_to_both=".services | .instance.environment.RIFTAL_DB_PASSWORD_ACCOUNTS == \"$ACCOUNTS_PW\"
  and .[\"instance-b\"].environment.RIFTAL_DB_PASSWORD_ACCOUNTS == \"$ACCOUNTS_PW\"
  and ([.[] | select(.environment.RIFTAL_DB_PASSWORD_ACCOUNTS != null)] | length == 2)"
check "instance and instance-b get RIFTAL_DB_PASSWORD_ACCOUNTS from images/.env and no other service does" \
  'jq -e "$password_to_both" <<<"$real" >/dev/null'
check "an instance-b without the password is caught" \
  '! jq -e "$password_to_both" <<<"$(edited "/instance-b:/,\$ {/RIFTAL_DB_PASSWORD_ACCOUNTS:/d}")" >/dev/null'
# PocketMine services whose command does not hand over to require-accounts.sh
# ahead of the script that starts PocketMine.
unaccounted() {
  jq -r '.services | to_entries[] | select(.value.image | test("pocketmine"))
    | select((.value.command | index(["bash", "/plugins/require-accounts.sh"])) as $at
      | $at == null or $at + 2 >= (.value.command | length))
    | .key' <<<"$1"
}
check "instance and instance-b both run require-accounts.sh before their start script" \
  '[ -z "$(unaccounted "$real")" ]'
check "an instance-b that skips it is caught" \
  '[ "$(unaccounted "$(edited "s#\"bash\", \"/plugins/require-accounts.sh\", ##")")" = instance-b ]'

# Runs a copy of require-accounts.sh with /plugins and /data moved under a
# scratch root, handing over to a printf. /plugins holds RiftalCustody.phar,
# the accounts config and each path in $1; the rest are environment
# assignments.
accounts() {
  local root="$work/accounts" phar
  rm -rf "$root"
  mkdir -p "$root/plugins/instance-only" "$root/data"
  printf phar > "$root/plugins/RiftalCustody.phar"
  cp "$ACCOUNTS_CONFIG" "$root/plugins/"
  for phar in $1; do printf phar > "$root/plugins/$phar"; done
  shift
  sed -e "s#/plugins#$root/plugins#g; s#/data#$root/data#g" "$DIR/../require-accounts.sh" > "$root/require.sh"
  env -i PATH="$PATH" "$@" bash "$root/require.sh" printf '%s|' a "b c" > "$root/out" 2>&1
}
a="$work/accounts"
both="RiftalAccounts.phar contracts.phar"
check "with both phars and the password, the config lands on the volume and the start command runs intact" \
  'accounts "$both" RIFTAL_DB_PASSWORD_ACCOUNTS="$ACCOUNTS_PW" &&
    cmp -s "$ACCOUNTS_CONFIG" "$a/data/plugin_data/RiftalAccounts/config.yml" && [ "$(cat "$a/out")" = "a|b c|" ]'
check "an unset RIFTAL_DB_PASSWORD_ACCOUNTS stops the boot before the start command, naming it" \
  '! accounts "$both" && ! grep -q "a|" "$a/out" && grep -q "RIFTAL_DB_PASSWORD_ACCOUNTS is not set" "$a/out"'
check "no contracts.phar stops the boot before the start command, naming it" \
  '! accounts RiftalAccounts.phar RIFTAL_DB_PASSWORD_ACCOUNTS="$ACCOUNTS_PW" && ! grep -q "a|" "$a/out" &&
    grep -qF "plugins/contracts.phar is not built" "$a/out"'
check "RiftalMines in instance-only without contracts.phar stops the boot before the start command, naming it" \
  '! accounts "RiftalAccounts.phar instance-only/RiftalMines.phar" RIFTAL_DB_PASSWORD_ACCOUNTS="$ACCOUNTS_PW" &&
    ! grep -q "a|" "$a/out" && grep -qF "plugins/contracts.phar is not built" "$a/out"'
check "RiftalMines in instance-only without RiftalAccounts.phar stops the boot before the start command, naming it" \
  '! accounts "contracts.phar instance-only/RiftalMines.phar" RIFTAL_DB_PASSWORD_ACCOUNTS="$ACCOUNTS_PW" &&
    ! grep -q "a|" "$a/out" && grep -qF "plugins/RiftalAccounts.phar is not built" "$a/out"'
check "instance-b's roster, RiftalCustody alone at the top of /plugins, stops the boot before the start command, naming RiftalAccounts.phar" \
  '! accounts "" RIFTAL_DB_PASSWORD_ACCOUNTS="$ACCOUNTS_PW" && ! grep -q "a|" "$a/out" &&
    grep -qF "plugins/RiftalAccounts.phar is not built" "$a/out" && [ ! -e "$a/data/plugin_data" ]'

printf '\n== the world index reaches every plugin that reads it (riftal-infra#293)\n'
INDEX="$DIR/../../../designer/world_index.json"
# PocketMine services in images/compose.yaml that do not run the delivery
# script straight after boot-gate.sh or do not get the designer index
# mounted read-only for it.
undelivered() {
  jq -r '.services | to_entries[] | select(.value.image | test("pocketmine"))
    | select((.value.command[2:4] != ["bash", "/plugins/deliver-world-index.sh"])
      or (any(.value.volumes[]?; .target == "/etc/riftal/world_index.json"
        and (.source | endswith("designer/world_index.json")) and .read_only) | not))
    | .key' <<<"$1"
}
check "instance and instance-b both run the delivery with the designer index mounted" \
  '[ -z "$(undelivered "$real")" ] &&
    [ "$(jq -c ".services.instance.command[-2:]" <<<"$real")" = "[\"bash\",\"/plugins/instance-only/start-instance.sh\"]" ] &&
    [ "$(jq -c ".services[\"instance-b\"].command[-2:]" <<<"$real")" = "[\"bash\",\"/plugins/instance-b/start.sh\"]" ]'
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
check "RiftalRanks, RiftalRiots, RiftalEconomy, RiftalMines, RiftalGangs and RiftalPlots each get the designer index byte for byte, stale copy replaced" \
  'deliver "$INDEX" true && cmp -s "$INDEX" "$d/RiftalRanks/world_index.json" &&
    cmp -s "$INDEX" "$d/RiftalRiots/world_index.json" &&
    cmp -s "$INDEX" "$d/RiftalEconomy/world_index.json" &&
    cmp -s "$INDEX" "$d/RiftalMines/world_index.json" &&
    cmp -s "$INDEX" "$d/RiftalGangs/world_index.json" &&
    cmp -s "$INDEX" "$d/RiftalPlots/world_index.json"'
check "the copies belong to the uid the script runs as, uid 1000 in the image" \
  'deliver "$INDEX" true && [ -f "$d/RiftalRiots/world_index.json" ] && [ -z "$(find "$d" ! -user "$me")" ]'
check "the start command runs after delivery with its arguments intact" \
  'deliver "$INDEX" printf "%s|" a "b c" && [ "$(cat "$work/deliver/out")" = "a|b c|" ]'
# cp's own error on a missing index also names the path, so only the guard's
# "is not mounted" tells the guard apart from cp failing under set -e.
check "a missing index stops the boot before the start command, saying it is not mounted" \
  '! deliver "" printf started && ! grep -q started "$work/deliver/out" &&
    grep -q "etc/world_index.json is not mounted;" "$work/deliver/out"'

printf '\n== link-replaced.sh gives pharynx the folder a virion requires (riftal-infra#579)\n'
# Lays out vendor/ as composer install leaves it for mines: libasynql, a
# virion, requires pocketmine/pocketmine-mp. Pinned, the fork replaces that
# name. Unpinned, the name is installed itself, and a package replacing a name
# no virion requires sits beside it.
fixture() {
  local root="$work/link/$1" core
  rm -rf "$root"
  mkdir -p "$root/vendor/composer" "$root/vendor/poggit/libasynql"
  local virion='{"name": "poggit/libasynql", "require": {"pocketmine/pocketmine-mp": "^5.0.0"}, "extra": {"virion": {"spec": "3.0"}}}'
  if [ "$1" = pinned ]; then
    core='{"name": "axolotl-pm/pocketmine-mp", "replace": {"pocketmine/pocketmine-mp": "5.49.1"}}'
    mkdir -p "$root/vendor/axolotl-pm/pocketmine-mp"
  else
    core='{"name": "pocketmine/pocketmine-mp"}, {"name": "x/polyfill", "replace": {"symfony/polyfill-ctype": "*"}}'
    mkdir -p "$root/vendor/pocketmine/pocketmine-mp" "$root/vendor/x/polyfill"
  fi
  printf '{"packages": [%s, %s]}\n' "$virion" "$core" > "$root/vendor/composer/installed.json"
}
# Runs link-replaced.sh in the fixture $1 as the README's build does, from the
# plugin folder, in a PHP image so the host needs no PHP. Prints its output.
link() {
  docker run --rm --network none -m 1g --cpus 1 --user "$(id -u):$(id -g)" \
    -v "$work/link/$1:/p" -v "$DIR/link-replaced.sh:/link-replaced.sh:ro" -w /p \
    php:8.3-cli-alpine sh /link-replaced.sh
}
pinned="$work/link/pinned/vendor"
fixture pinned
fixture unpinned
check "pinned to the fork, vendor/pocketmine/pocketmine-mp is linked to vendor/axolotl-pm/pocketmine-mp" \
  'out="$(link pinned)" && [ -L "$pinned/pocketmine/pocketmine-mp" ] &&
    [ "$(cd "$pinned/pocketmine/pocketmine-mp" && pwd -P)" = "$(cd "$pinned/axolotl-pm/pocketmine-mp" && pwd -P)" ] &&
    [ "$out" = "linked vendor/pocketmine/pocketmine-mp to vendor/axolotl-pm/pocketmine-mp, which replaces it" ]'
check "a second run links nothing and leaves the link as it was" \
  'out="$(link pinned)" && [ -z "$out" ] &&
    [ "$(readlink "$pinned/pocketmine/pocketmine-mp")" = ../axolotl-pm/pocketmine-mp ]'
check "unpinned, nothing is linked, not even a replaced name no virion requires" \
  'out="$(link unpinned)" && [ -z "$out" ] && [ ! -e "$work/link/unpinned/vendor/symfony" ] &&
    [ -z "$(find "$work/link/unpinned" -type l)" ]'

printf '\n== the template keeps the plugin'"'"'s shipped tuning (riftal-infra#262)\n'
# The plugin throws on enable without a scalar key and reads a missing
# join_teleport as off, so the template has to carry them. CI checks out this
# repository alone and holds no token for the private riftal-game, so there
# the comparison is reported as skipped rather than passed.
# Sets SHIPPED, RANKS_SHIPPED, ACCOUNTS_SHIPPED and ECONOMY_SHIPPED to
# riftal-game's shipped configs under RIFTAL_GAME_DIR, or under the default
# sibling checkout when it is unset or empty.
shipped_configs() {
  local game="${RIFTAL_GAME_DIR:-$DIR/../../../../riftal-game}"
  SHIPPED="$game/mines/resources/config.yml"
  RANKS_SHIPPED="$game/ranks/resources/config.yml"
  ACCOUNTS_SHIPPED="$game/accounts/resources/config.yml"
  ECONOMY_SHIPPED="$game/economy/resources/config.yml"
}
shipped_configs
SKIPPED=0
# That skip covers only an absent default sibling checkout, and each skipped
# assertion is counted, so EXPECTED_ASSERTIONS catches one that was deleted.
# A RIFTAL_GAME_DIR naming no config fails: a mistyped path is a broken run,
# not a missing checkout. An empty RIFTAL_GAME_DIR counts as unset. $3 names
# the shipped file when it is not the mines config.
drift() {
  if [ -f "${3:-$SHIPPED}" ]; then check "$1" "$2"
  elif [ -n "${RIFTAL_GAME_DIR:-}" ]; then fail "$1: RIFTAL_GAME_DIR is set but ${3:-$SHIPPED} does not exist"
  else SKIPPED=$((SKIPPED + 1)); fi
}
check "an explicit RIFTAL_GAME_DIR without the mines config fails the drift assertion" \
  '[ "$(RIFTAL_GAME_DIR=/nonexistent; shipped_configs; FAILURES=0; SKIPPED=0; drift x true >/dev/null; echo "$FAILURES $SKIPPED")" = "1 0" ]'
check "an explicit RIFTAL_GAME_DIR without a named shipped config fails the drift assertion" \
  '[ "$(RIFTAL_GAME_DIR=/nonexistent; SHIPPED="$TEMPLATE"; FAILURES=0; SKIPPED=0; drift x true /nonexistent/r.yml >/dev/null; echo "$FAILURES $SKIPPED")" = "1 0" ]'
check "an absent default sibling checkout skips the drift assertion" \
  '[ "$(unset RIFTAL_GAME_DIR; SHIPPED=/nonexistent/c.yml; FAILURES=0; SKIPPED=0; drift x true >/dev/null; echo "$FAILURES $SKIPPED")" = "0 1" ]'
# The shipped config shipped_configs derives for $1, the name of one of the
# variables it sets, under a scratch RIFTAL_GAME_DIR, so a path derived
# without it cannot match.
derived() { (RIFTAL_GAME_DIR="$work/game"; shipped_configs; printf '%s' "${!1}"); }
check "RIFTAL_GAME_DIR names the mines config the drift assertions read" \
  '[ "$(derived SHIPPED)" = "$work/game/mines/resources/config.yml" ]'
check "RIFTAL_GAME_DIR names the ranks config the drift assertions read" \
  '[ "$(derived RANKS_SHIPPED)" = "$work/game/ranks/resources/config.yml" ]'
check "RIFTAL_GAME_DIR names the accounts config the drift assertions read" \
  '[ "$(derived ACCOUNTS_SHIPPED)" = "$work/game/accounts/resources/config.yml" ]'
check "RIFTAL_GAME_DIR names the economy config the drift assertions read" \
  '[ "$(derived ECONOMY_SHIPPED)" = "$work/game/economy/resources/config.yml" ]'
# Every top-level key, whether it holds a scalar or opens a section.
keys() { grep -oE '^[^[:space:]#-][^:]*:' "$1" | sort -u; }
# Top-level keys holding a scalar. The database and worlds sections hold
# none, so the values the template overrides on purpose stay out of it.
tuning() { grep -E '^[^[:space:]#-][^:]*:[[:space:]]*[^[:space:]#]' "$1" | sed 's/[[:space:]]*$//' | sort; }
# Every section's header and entries, comments and blank lines dropped,
# except database and worlds, which the template overrides on purpose.
sections() {
  awk '/^[^[:space:]#]/ { keep = /^[^:]*:[[:space:]]*$/ && !/^(database|worlds):/ }
    keep && /[^[:space:]]/ && !/^[[:space:]]*#/' "$1" | sed 's/[[:space:]]*$//'
}
# Top-level keys in the shipped file $1 that the template lacks.
missing() { comm -23 <(keys "$1") <(keys "$TEMPLATE"); }
mutated="$work/shipped.yml"
drift "every scalar key in riftal-game's mines config.yml matches the template" \
  '[ -n "$(tuning "$SHIPPED")" ] && [ "$(tuning "$SHIPPED")" = "$(tuning "$TEMPLATE")" ]'
drift "every top-level key in riftal-game's mines config.yml, section or scalar, is in the template" \
  '[ -n "$(keys "$SHIPPED")" ] && [ -z "$(missing "$SHIPPED")" ]'
drift "every section in riftal-game's mines config.yml but database and worlds matches the template" \
  '[ -n "$(sections "$SHIPPED")" ] && [ "$(sections "$SHIPPED")" = "$(sections "$TEMPLATE")" ]'
drift "a shipped join_teleport value the template does not carry is caught" \
  'sed "s/^  location: .*/  location: \"elsewhere\"/" "$SHIPPED" > "$mutated" &&
    ! cmp -s "$SHIPPED" "$mutated" && [ "$(sections "$mutated")" != "$(sections "$TEMPLATE")" ]'
drift "a shipped value the template does not carry is caught" \
  'sed "s/^refill_blocks_per_tick:.*/refill_blocks_per_tick: 1/" "$SHIPPED" > "$mutated" &&
    [ "$(tuning "$mutated")" != "$(tuning "$TEMPLATE")" ]'
drift "a shipped scalar whose key holds a digit or hyphen is caught" \
  '{ cat "$SHIPPED"; printf "refill_v2-budget: 3\n"; } > "$mutated" &&
    [ "$(tuning "$mutated")" != "$(tuning "$TEMPLATE")" ]'
drift "a shipped section the template lacks is caught" \
  '{ cat "$SHIPPED"; printf "messages:\n  reset: x\n"; } > "$mutated" &&
    [ "$(missing "$mutated")" = "messages:" ]'
drift "riftal-game's ranks config.yml has no top-level key or scalar value the ranks config lacks" \
  '[ -n "$(keys "$RANKS_SHIPPED")" ] && [ -z "$(comm -23 <(keys "$RANKS_SHIPPED") <(keys "$RANKS_CONFIG"))" ] &&
    [ "$(tuning "$RANKS_SHIPPED")" = "$(tuning "$RANKS_CONFIG")" ]' "$RANKS_SHIPPED"
# The lines inside the top-level database section, comments dropped, schema
# excepted: the one line the ranks config overrides on purpose.
dbsection() {
  sed -n '/^database:/,/^[^[:space:]]/{/^[[:space:]]/p}' "$1" |
    grep -vE '^[[:space:]]*(#|schema:)' | sed 's/[[:space:]]*$//'
}
drift "every database line in riftal-game's ranks config.yml but the schema matches the ranks config" \
  '[ -n "$(dbsection "$RANKS_SHIPPED")" ] && [ "$(dbsection "$RANKS_SHIPPED")" = "$(dbsection "$RANKS_CONFIG")" ]' \
  "$RANKS_SHIPPED"
drift "a shipped database.port the ranks config does not carry is caught" \
  'sed "s/^  port:.*/  port: 3307/" "$RANKS_SHIPPED" > "$mutated" &&
    [ "$(dbsection "$mutated")" != "$(dbsection "$RANKS_CONFIG")" ]' "$RANKS_SHIPPED"
# Every line but comments, blanks and the schema, the one line the accounts
# config overrides on purpose.
settings() { grep -vE '^[[:space:]]*(#|$|schema:)' "$1" | sed 's/[[:space:]]*$//'; }
drift "every line in riftal-game's accounts config.yml but the schema matches the accounts config" \
  '[ -n "$(settings "$ACCOUNTS_SHIPPED")" ] && [ "$(settings "$ACCOUNTS_SHIPPED")" = "$(settings "$ACCOUNTS_CONFIG")" ]' \
  "$ACCOUNTS_SHIPPED"
drift "a shipped database.port the accounts config does not carry is caught" \
  'sed "s/^  port:.*/  port: 3307/" "$ACCOUNTS_SHIPPED" > "$mutated" &&
    [ "$(settings "$mutated")" != "$(settings "$ACCOUNTS_CONFIG")" ]' "$ACCOUNTS_SHIPPED"
drift "every line in riftal-game's economy config.yml but the schema matches the economy config" \
  '[ -n "$(settings "$ECONOMY_SHIPPED")" ] && [ "$(settings "$ECONOMY_SHIPPED")" = "$(settings "$ECONOMY_CONFIG")" ]' \
  "$ECONOMY_SHIPPED"
drift "a shipped sell shop price the economy config does not carry is caught" \
  'sed "s/^    \"minecraft:coal\": .*/    \"minecraft:coal\": 6/" "$ECONOMY_SHIPPED" > "$mutated" &&
    [ "$(settings "$mutated")" != "$(settings "$ECONOMY_CONFIG")" ]' "$ECONOMY_SHIPPED"
if [ "$SKIPPED" -ne 0 ]; then
  printf '::warning::%s assertions skipped: no riftal-game config at %s, %s, %s or %s; set RIFTAL_GAME_DIR\n' \
    "$SKIPPED" "$SHIPPED" "$RANKS_SHIPPED" "$ACCOUNTS_SHIPPED" "$ECONOMY_SHIPPED"
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
