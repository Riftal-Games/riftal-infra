#!/usr/bin/env bash
# Self-test for the release image's start command (riftal-infra#1253). Builds
# two release tags over stub plugins that differ only in version, then boots
# tag N, then N+1, then N again on one named /data volume and one reused
# /plugins volume that holds stale copies of two phars. Each boot must load the
# phars of its own tag: the sha256 the start command reports for every roster
# file equals its entry in the image's labels, the log enables exactly the
# roster's plugins at the tag's version, and no stale copy is touched. Also
# checks the refusals that stop a boot before PocketMine, the rendered configs
# and that /opt/riftal/plugins cannot be written by the server's user.
#
# The tags carry two zones, built from one level the core image generates into
# riftal_smoke_ volumes of this test's own, never the dev stack's. The first boot
# on an empty /data must seed both zones and deliver the index to the six plugin
# folders, the second must seed nothing and log no LEVEL DIFFERS, and a third on
# a volume whose seeded zone has another content_sha256 must boot and log it.
# Each of the boot refusals of ADR 043 item 3 must stop the start command with
# its reason and leave a /data it was given empty: an index or a zone manifest
# mounted over the image's, a zone the image lacks, and every bad value of
# RIFTAL_LEVEL_ZONES and POCKETMINE_ARGS. A level folder whose manifest is the
# tag's and whose tree is not is refused by seed-levels.sh with no /data/worlds.
# Needs the core image pinned in images/core-image.sha and a committed, clean
# checkout, since the tags name the riftal-infra commit. Everything it creates
# is named riftal_smoke_ and removed on exit.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/release-image.sh"
. "$DIR/release-fixture.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=49
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

sha="$(tr -d '[:space:]' < "$DIR/../images/core-image.sha")"
image="riftal_smoke_start/pocketmine-mp"
GAME_COMMIT=0123456789abcdef0123456789abcdef01234567
infra_sha="$(infra_commit "$DIR/..")"
tag_n="$(release_tag 2026-10-20 "$sha" "$GAME_COMMIT" "$infra_sha")"
tag_m="$(release_tag 2026-10-21 "$sha" "$GAME_COMMIT" "$infra_sha")"
data_vol="riftal_smoke_start_$$_data"
plugins_vol="riftal_smoke_start_$$_plugins"
cname="riftal_smoke_start_$$"
level_prefix="riftal_smoke_start_$$_level_"
gen_vol="riftal_smoke_start_$$_gen"
empty_vol="riftal_smoke_start_$$_empty"
tree_vol="riftal_smoke_start_$$_tree"
level_vols=("${level_prefix}smoke_a" "${level_prefix}smoke_b" "${level_prefix}tamper" "${level_prefix}badtree")
work="$(mktemp -d)"
chmod 0777 "$work"
cleanup() {
  exec 3>&- 2>/dev/null || true
  docker stop -t 60 "$cname" >/dev/null 2>&1 || true
  docker rm -v "$cname" >/dev/null 2>&1 || true
  docker volume rm "$data_vol" "$plugins_vol" "$gen_vol" "$empty_vol" "$tree_vol" "${level_vols[@]}" >/dev/null 2>&1 || true
  docker image rm "$image:$tag_n" "$image:$tag_m" >/dev/null 2>&1 || true
  docker image rm "riftal_smoke_start/backup:$tag_n" "riftal_smoke_start/backup:$tag_m" \
    "riftal_smoke_start/backup-base:$tag_n" "riftal_smoke_start/backup-base:$tag_m" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
# A server that has already exited closes its stdin, and writing stop to it
# must report the failed boot through the assertions, not end the script.
trap '' PIPE

# $1 log file, then the arguments of docker run ending in the image. Starts the
# server, waits for Done, sends stop on stdin and waits for the container to
# exit. The container removes itself when it stops; --rm removes only anonymous
# volumes, so named volumes survive for the next boot.
serve() {
  local log="$1" fifo="$work/stdin" i pid
  shift
  rm -f "$fifo"
  mkfifo "$fifo"
  docker run -i --rm --name "$cname" -m 2g --cpus 2 --network none "$@" <"$fifo" >"$log" 2>&1 &
  pid=$!
  exec 3>"$fifo"
  for i in $(seq 1 120); do
    grep -q 'Done (' "$log" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  { echo stop >&3; } 2>/dev/null || true
  exec 3>&-
  for i in $(seq 1 90); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  wait "$pid" || true
}

cat > "$work/stub.php" <<'PHP'
<?php
[, $out, $version] = $argv;
$files = [
  'RiftalCustody.phar' => ['RiftalCustody', null],
  'RiftalAccounts.phar' => ['RiftalAccounts', 'RiftalContracts'],
  'contracts.phar' => ['RiftalContracts', null],
  'RiftalMines.phar' => ['RiftalMines', 'RiftalContracts'],
  'RiftalRanks.phar' => ['RiftalRanks', 'RiftalContracts'],
  'RiftalEconomy.phar' => ['RiftalEconomy', 'RiftalContracts'],
  'RiftalGangs.phar' => ['RiftalGangs', 'RiftalContracts'],
  'RiftalRiots.phar' => ['RiftalRiots', 'RiftalContracts'],
  'RiftalPlots.phar' => ['RiftalPlots', 'RiftalContracts'],
  'RiftalAnvil.phar' => ['RiftalAnvil', 'RiftalContracts'],
];
foreach ($files as $file => [$name, $depend]) {
  $phar = new Phar("$out/$file");
  $yml = "name: $name\nversion: $version\nmain: Stub\\$name\\Main\napi: 5.0.0\n";
  $phar->addFromString('plugin.yml', $depend === null ? $yml : $yml . "depend: [$depend]\n");
  $phar->addFromString('src/Stub/' . $name . '/Main.php',
    "<?php\nnamespace Stub\\$name;\nclass Main extends \\pocketmine\\plugin\\PluginBase {}\n");
}
PHP

export GAME_COMMIT
export GRANTS_SQL="$work/grants.sql"
printf 'REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines;\n' > "$GRANTS_SQL"
mkdir "$work/migrations"
printf 'CREATE TABLE smoke_start (id INT);\n' > "$work/migrations/0001_start.sql"
export MIGRATIONS_DIR="$work/migrations" BACKUP_IMAGE="riftal_smoke_start/backup"

core_image
for version in 1.0.0 2.0.0 0.0.1; do
  mkdir -m 0777 "$work/$version"
  docker run --rm -m 1g --cpus 1 -v "$work:/work" --entrypoint php "$CORE_IMAGE" \
    -d phar.readonly=0 /work/stub.php "/work/$version" "$version"
done

core_id="$(docker image inspect --format '{{.Id}}' "$CORE_IMAGE")"
content_a="$(printf 'a%.0s' {1..64})"
content_b="$(printf 'b%.0s' {1..64})"
content_other="$(printf 'c%.0s' {1..64})"
docker volume create "$gen_vol" >/dev/null
serve "$work/gen.log" -v "$gen_vol:/data" \
  -e "POCKETMINE_ARGS=--level-name=smoke_a --level-type=flat --xbox-auth=false --auto-report.enabled=0" "$CORE_IMAGE"
for vol in "${level_vols[@]}"; do
  docker volume create "$vol" >/dev/null
done
docker run --rm -m 1g --cpus 1 --network none --user root -v "$gen_vol:/gen:ro" \
  -v "${level_vols[0]}:/0" -v "${level_vols[1]}:/1" -v "${level_vols[2]}:/2" -v "${level_vols[3]}:/3" \
  --entrypoint bash "$CORE_IMAGE" -c 'for d in 0 1 2 3; do cp -R /gen/worlds/smoke_a/. "/$d/"; done'
fixture_manifest "${level_vols[0]}" "$content_a"
fixture_manifest "${level_vols[1]}" "$content_b"
fixture_manifest "${level_vols[2]}" "$content_other"
fixture_manifest "${level_vols[3]}" "$content_a"
docker run --rm -m 1g --cpus 1 --network none --user root -v "${level_vols[3]}:/level" \
  --entrypoint bash "$CORE_IMAGE" -c 'printf "added after the manifest\n" >/level/db/added'
mkdir "$work/locks"
fixture_lock "$work/locks" smoke_a "$content_a" "$core_id"
fixture_lock "$work/locks" smoke_b "$content_b" "$core_id"
export LEVEL_LOCKS_DIR="$work/locks" LEVEL_VOLUME_PREFIX="$level_prefix"

RELEASE_IMAGE=$image RELEASE_DATE=2026-10-20 main "$work/1.0.0" >/dev/null && pass "tag N builds" || fail "tag N did not build"
RELEASE_IMAGE=$image RELEASE_DATE=2026-10-21 main "$work/2.0.0" >/dev/null && pass "tag N+1 builds" || fail "tag N+1 did not build"

docker volume create "$plugins_vol" >/dev/null
docker volume create "$data_vol" >/dev/null
docker run --rm -m 1g --cpus 1 -v "$plugins_vol:/plugins" -v "$work/0.0.1:/src:ro" \
  --entrypoint cp "$image:$tag_n" /src/RiftalCustody.phar /src/RiftalMines.phar /plugins/

# $1 tag, then VAR=value pairs. Prints the output of the start command and
# returns its exit status; the server is never started because every case
# given here is refused first.
refused() {
  local ref="$image:$1" args=() pair
  shift
  for pair in "$@"; do args+=(-e "$pair"); done
  docker run --rm -m 1g --cpus 1 --network none \
    -e RIFTAL_DB_HOST=dbhost.test -e RIFTAL_DB_SCHEMA=riftal_test \
    -e RIFTAL_DB_PASSWORD_ACCOUNTS=x -e RIFTAL_DB_PASSWORD_MINES=x \
    -e RIFTAL_DB_PASSWORD_RANKS=x -e RIFTAL_DB_PASSWORD_ECONOMY=x \
    "${args[@]}" "$ref" 2>&1
}

expect_refusal() {
  local what="$1" want="$2" out
  shift 2
  if out="$(refused "$tag_n" "$@")"; then
    fail "$what was accepted"
  elif grep -qF -- "$want" <<<"$out"; then
    pass "$what is refused naming $want"
  else
    fail "$what was refused without naming $want: $out"
  fi
}

expect_refusal "an unset accounts password" RIFTAL_DB_PASSWORD_ACCOUNTS RIFTAL_DB_PASSWORD_ACCOUNTS=
for pair in MINES:RiftalMines RANKS:RiftalRanks ECONOMY:RiftalEconomy; do
  expect_refusal "an unset ${pair%%:*} password" "RIFTAL_DB_PASSWORD_${pair%%:*}" \
    "RIFTAL_PLUGINS=${pair##*:}" "RIFTAL_DB_PASSWORD_${pair%%:*}="
done
expect_refusal "an unknown plugin" RiftalPlots RIFTAL_PLUGINS=RiftalPlots
expect_refusal "a plugins path in the arguments" --plugins=/plugins POCKETMINE_ARGS=--plugins=/plugins
expect_refusal "an unset database host" RIFTAL_DB_HOST RIFTAL_DB_HOST=

if docker run --rm -m 1g --cpus 1 --entrypoint sh "$image:$tag_n" -c 'touch /opt/riftal/plugins/extra.phar' >/dev/null 2>&1; then
  fail "the server's user can add a file to /opt/riftal/plugins"
else
  pass "the server's user cannot add a file to /opt/riftal/plugins"
fi

# $1 the case, $2 the message the refusal must carry, then VAR=value to change a
# variable of the boot's environment or -VAR to unset it, and after -- the
# arguments of docker run that put another file or volume over the image's. The
# refusal must leave /data empty, or with REFUSAL_ABSENT not under it, in the
# volume REFUSAL_DATA when that is set.
expect_level_refusal() {
  local what="$1" want="$2" out key data="${REFUSAL_DATA:-$empty_vol}" run=() mounts=()
  local -A env=([RIFTAL_DB_HOST]=dbhost.test [RIFTAL_DB_SCHEMA]=riftal_test [RIFTAL_DB_PASSWORD_ACCOUNTS]=x
    [RIFTAL_LEVEL_ZONES]="smoke_a smoke_b" [POCKETMINE_ARGS]="--level-name=smoke_a --xbox-auth=false --auto-report.enabled=0")
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    case "$1" in
      -*) unset "env[${1#-}]" ;;
      *) env[${1%%=*}]="${1#*=}" ;;
    esac
    shift
  done
  [ "$#" -eq 0 ] || shift
  mounts=("$@")
  for key in "${!env[@]}"; do run+=(-e "$key=${env[$key]}"); done
  if out="$(docker run --rm -m 1g --cpus 1 --network none -v "$data:/data" "${mounts[@]}" "${run[@]}" "$image:$tag_n" 2>&1)"; then
    fail "$what was accepted"
  elif ! grep -qF -- "$want" <<<"$out"; then
    fail "$what was refused without naming $want: $out"
  elif [ -n "${REFUSAL_ABSENT:-}" ]; then
    if docker run --rm -m 1g --cpus 1 -v "$data:/data" --entrypoint test "$image:$tag_n" ! -e "$REFUSAL_ABSENT"; then
      pass "$what is refused naming $want, with nothing at $REFUSAL_ABSENT"
    else
      fail "$what was refused after $REFUSAL_ABSENT was written"
    fi
  elif [ -n "$(docker run --rm -m 1g --cpus 1 -v "$data:/data" --entrypoint find "$image:$tag_n" /data -mindepth 1)" ]; then
    fail "$what was refused after /data was written"
  else
    pass "$what is refused naming $want, with nothing written to /data"
  fi
}

docker volume create "$empty_vol" >/dev/null
docker volume create "$tree_vol" >/dev/null
printf '{"unrelated": true}\n' >"$work/other-index.json"
expect_level_refusal "a file mounted over the index" "/etc/riftal/world_index.json: FAILED" \
  -- -v "$work/other-index.json:/etc/riftal/world_index.json:ro"
expect_level_refusal "a volume with another manifest over a zone's level" "/etc/riftal/levels/smoke_a/level-manifest.json: FAILED" \
  -- -v "${level_prefix}tamper:/etc/riftal/levels/smoke_a:ro"
REFUSAL_DATA="$tree_vol" REFUSAL_ABSENT=/data/worlds expect_level_refusal \
  "a volume with the tag's manifest and another tree over a zone's level" "seed-levels: smoke_a: the file tree of" \
  -- -v "${level_prefix}badtree:/etc/riftal/levels/smoke_a:ro"
expect_level_refusal "a listed zone the image lacks" "this image carries no level smoke_c" "RIFTAL_LEVEL_ZONES=smoke_a smoke_c"
expect_level_refusal "an unset RIFTAL_LEVEL_ZONES" "RIFTAL_LEVEL_ZONES is unset or empty" -RIFTAL_LEVEL_ZONES
expect_level_refusal "an empty RIFTAL_LEVEL_ZONES" "RIFTAL_LEVEL_ZONES is unset or empty" RIFTAL_LEVEL_ZONES=
expect_level_refusal "a RIFTAL_LEVEL_ZONES with a bad character" "RIFTAL_LEVEL_ZONES holds a character outside" "RIFTAL_LEVEL_ZONES=smoke_a;smoke_b"
expect_level_refusal "an unset POCKETMINE_ARGS" "POCKETMINE_ARGS is unset or empty" -POCKETMINE_ARGS
expect_level_refusal "an empty POCKETMINE_ARGS" "POCKETMINE_ARGS is unset or empty" POCKETMINE_ARGS=
expect_level_refusal "a POCKETMINE_ARGS with a bad character" "POCKETMINE_ARGS holds a character outside" 'POCKETMINE_ARGS=--level-name=smoke_a;x'
expect_level_refusal "a --level-name outside RIFTAL_LEVEL_ZONES" "--level-name zone 'smoke_c' is not in RIFTAL_LEVEL_ZONES" POCKETMINE_ARGS=--level-name=smoke_c
expect_level_refusal "two --level-name tokens" "holds 2 --level-name tokens" "POCKETMINE_ARGS=--level-name=smoke_a --level-name=smoke_b"
expect_level_refusal "no --level-name" "holds no --level-name" POCKETMINE_ARGS=--xbox-auth=false
expect_level_refusal "a bare --level-name" "token '--level-name' is not --level-name=<zone>" POCKETMINE_ARGS=--level-name
expect_level_refusal "a --worlds token beside a valid --level-name" "token '--worlds=mine_b' would generate" "POCKETMINE_ARGS=--level-name=smoke_a --worlds=mine_b"
expect_level_refusal "a value token before --level-name" "token 'false' is not a single long option" "POCKETMINE_ARGS=--xbox-auth false --level-name=smoke_a"
expect_level_refusal "a zone outside [a-z0-9_]+" "zone 'Smoke_a' is not a name matching" "RIFTAL_LEVEL_ZONES=Smoke_a smoke_b"
expect_level_refusal "a repeated zone" "lists zone smoke_a more than once" "RIFTAL_LEVEL_ZONES=smoke_a smoke_a"

# $1 tag, $2 RIFTAL_PLUGINS, $3 log file. Boots on the shared volumes.
boot() {
  serve "$3" -v "$data_vol:/data" -v "$plugins_vol:/plugins" \
    -e RIFTAL_DB_HOST=dbhost.test -e RIFTAL_DB_SCHEMA=riftal_test \
    -e RIFTAL_DB_PASSWORD_ACCOUNTS=x -e RIFTAL_DB_PASSWORD_MINES=x \
    -e RIFTAL_DB_PASSWORD_RANKS=x -e RIFTAL_DB_PASSWORD_ECONOMY=x \
    -e "RIFTAL_PLUGINS=$2" \
    -e "RIFTAL_LEVEL_ZONES=smoke_a smoke_b" \
    -e "POCKETMINE_ARGS=--level-name=smoke_a --xbox-auth=false --auto-report.enabled=0" \
    "$image:$1"
}

# $1 tag, $2 RIFTAL_PLUGINS, $3 version the tag's stub phars carry.
check_boot() {
  local tag="$1" plugins="$2" version="$3" log="$work/boot-$1-$$.log"
  local label want_roster got_roster want_enabled got_enabled files=(RiftalCustody.phar RiftalAccounts.phar contracts.phar "${SHIPPED_PLUGINS[@]}") p
  for p in ${plugins//,/ }; do files+=("$p.phar"); done
  boot "$tag" "$plugins" "$log"

  label="$(docker image inspect --format '{{index .Config.Labels "org.riftal.phars"}},{{index .Config.Labels "org.riftal.script-plugins"}}' "$image:$tag")"
  want_roster="$(for p in "${files[@]}"; do tr , '\n' <<<"$label" | grep "^$p=" | sed 's/^\(.*\)=\(.*\)$/\2  \1/'; done | sort)"
  got_roster="$(sed -n 's/^roster //p' "$log" | sort)"
  if [ "$(wc -l <<<"$want_roster")" -eq "${#files[@]}" ] && [ "$got_roster" = "$want_roster" ]; then
    pass "$tag loaded the roster phars its label names, ${#files[@]} of them"
  else
    fail "$tag roster differs from its label. label: $want_roster / loaded: $got_roster"
  fi

  want_enabled="$(for p in "${files[@]}"; do n="${p%.*}"; v="$version"; [[ $p = *.php ]] && v="$(sed -n 's/^ \* @version //p' "$DIR/../images/plugins/$p")"; [ "$n" = contracts ] && n=RiftalContracts; echo "$n v$v"; done | sort)"
  got_enabled="$(sed -n 's/.*Enabling \([A-Za-z]* v[0-9.]*\).*/\1/p' "$log" | sort)"
  if [ "$got_enabled" = "$want_enabled" ]; then
    pass "$tag enabled exactly its roster at version $version"
  else
    fail "$tag enabled: $got_enabled / expected: $want_enabled"
  fi

  if grep -q 'v0\.0\.1' "$log"; then
    fail "$tag touched a stale phar in /plugins"
  else
    pass "$tag touched no stale phar in /plugins"
  fi
  if grep -Eq 'CRITICAL|ERROR|EMERGENCY|Exception' "$log"; then
    fail "$tag logged an error: $(grep -E 'CRITICAL|ERROR|EMERGENCY|Exception' "$log" | head -3)"
  else
    pass "$tag log holds no error"
  fi
  if grep -q 'Stopping other threads' "$log"; then
    pass "$tag stopped cleanly on stop"
  else
    fail "$tag did not reach its shutdown line: $(tail -5 "$log")"
  fi
}

levels_label="$(docker image inspect --format '{{index .Config.Labels "org.riftal.levels"}}' "$image:$tag_n")"
index_label="$(docker image inspect --format '{{index .Config.Labels "org.riftal.world-index-sha256"}}' "$image:$tag_n")"
log_n="$work/boot-$tag_n-$$.log"
log_m="$work/boot-$tag_m-$$.log"

check_boot "$tag_n" "RiftalMines RiftalRanks RiftalEconomy" 1.0.0
missing=""
for entry in ${levels_label//,/ }; do
  zone="${entry%%=*}"
  hashes="${entry#*=}"
  grep -qF "seed-levels: $zone seeded at /data/worlds/$zone content_sha256=${hashes%%:*} tree_sha256=${hashes##*:}" "$log_n" \
    || missing+=" $zone"
done
if [ "$(wc -w <<<"${levels_label//,/ }")" -eq 2 ] && [ -z "$missing" ]; then
  pass "the first boot on an empty /data seeded both zones with the tag's hashes"
else
  fail "the first boot did not seed:$missing, label $levels_label: $(grep seed-levels "$log_n")"
fi
delivered="$(docker run --rm -m 1g --cpus 1 -v "$data_vol:/data" --entrypoint sha256sum "$image:$tag_n" \
  /data/plugin_data/{RiftalRanks,RiftalRiots,RiftalEconomy,RiftalMines,RiftalGangs,RiftalPlots}/world_index.json | cut -d' ' -f1 | sort | uniq -c | tr -s ' ')"
if [ "$delivered" = " 6 $index_label" ]; then
  pass "the index reached the six plugin folders, each equal to the image's"
else
  fail "the delivered indexes were: $delivered, the image's is $index_label"
fi
cfg="$(docker run --rm -m 1g --cpus 1 -v "$data_vol:/data" --entrypoint cat "$image:$tag_n" \
  /data/plugin_data/RiftalMines/config.yml /data/plugin_data/RiftalAccounts/config.yml)"
if [ "$(grep -c '^  host: "dbhost.test"' <<<"$cfg")" -eq 2 ] && [ "$(grep -c '^  schema: "riftal_test"' <<<"$cfg")" -eq 2 ]; then
  pass "the Mines and Accounts configs carry the given host and schema"
else
  fail "the rendered configs lack the given host or schema: $cfg"
fi
if [ "$(grep -c '^  password: ""' <<<"$cfg")" -eq 2 ]; then
  pass "the rendered configs hold no password"
else
  fail "a rendered config holds a password: $cfg"
fi
check_boot "$tag_m" "RiftalEconomy" 2.0.0
if [ "$(grep -c 'seed-levels: smoke_[ab] present at' "$log_m")" -eq 2 ] && ! grep -qE 'seeded at|LEVEL DIFFERS' "$log_m"; then
  pass "the second boot seeded nothing and logged no LEVEL DIFFERS"
else
  fail "the second boot seeded or logged a difference: $(grep -E 'seed-levels|LEVEL' "$log_m")"
fi
docker run --rm -m 1g --cpus 1 -v "$data_vol:/data" --entrypoint sed "$image:$tag_n" \
  -i "s/\"content_sha256\": \"[0-9a-f]*\"/\"content_sha256\": \"$content_other\"/" /data/worlds/smoke_b/level-manifest.json
check_boot "$tag_n" "" 1.0.0
want_differs="LEVEL DIFFERS smoke_b seeded=$content_other tag=$content_b"
if [ "$(grep -c 'LEVEL DIFFERS' "$log_n")" -eq 1 ] && grep -qxF "$want_differs" "$log_n"; then
  pass "a volume whose seeded zone has another content_sha256 booted and logged: $want_differs"
else
  fail "the differing zone was not logged as '$want_differs': $(grep -E 'LEVEL' "$log_n")"
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
printf 'all %s assertions passed: each tag loaded its own phars and nothing from /plugins.\n' "$PASSES"
