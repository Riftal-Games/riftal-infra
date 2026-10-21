#!/usr/bin/env bash
# Self-test for the release image's start command (riftal-infra#1253). Builds
# two release tags over stub plugins that differ only in version, then boots
# tag N, then N+1, then N again on one named /data volume and one reused
# /plugins volume that holds stale copies of two phars. Each boot must load the
# phars of its own tag: the sha256 the start command reports for every roster
# phar equals the image's org.riftal.phars label, the log enables exactly the
# roster's plugins at the tag's version, and no stale copy is touched. Also
# checks the refusals that stop a boot before PocketMine, the rendered configs
# and that /opt/riftal/plugins cannot be written by the server's user.
# Needs the core image pinned in images/core-image.sha. Everything it creates
# is named riftal_smoke_ and removed on exit.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/release-image.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=27
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

sha="$(tr -d '[:space:]' < "$DIR/../images/core-image.sha")"
image="riftal_smoke_start/pocketmine-mp"
tag_n="core-2026-10-20-${sha:0:7}"
tag_m="core-2026-10-21-${sha:0:7}"
data_vol="riftal_smoke_start_$$_data"
plugins_vol="riftal_smoke_start_$$_plugins"
cname="riftal_smoke_start_$$"
work="$(mktemp -d)"
chmod 0777 "$work"
cleanup() {
  exec 3>&- 2>/dev/null || true
  docker stop -t 60 "$cname" >/dev/null 2>&1 || true
  docker rm -v "$cname" >/dev/null 2>&1 || true
  docker volume rm "$data_vol" "$plugins_vol" >/dev/null 2>&1 || true
  docker image rm "$image:$tag_n" "$image:$tag_m" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
# A server that has already exited closes its stdin, and writing stop to it
# must report the failed boot through the assertions, not end the script.
trap '' PIPE

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
];
foreach ($files as $file => [$name, $depend]) {
  $phar = new Phar("$out/$file");
  $yml = "name: $name\nversion: $version\nmain: Stub\\$name\\Main\napi: 5.0.0\n";
  $phar->addFromString('plugin.yml', $depend === null ? $yml : $yml . "depend: [$depend]\n");
  $phar->addFromString('src/Stub/' . $name . '/Main.php',
    "<?php\nnamespace Stub\\$name;\nclass Main extends \\pocketmine\\plugin\\PluginBase {}\n");
}
PHP

core_image
for version in 1.0.0 2.0.0 0.0.1; do
  mkdir -m 0777 "$work/$version"
  docker run --rm -m 1g --cpus 1 -v "$work:/work" --entrypoint php "$CORE_IMAGE" \
    -d phar.readonly=0 /work/stub.php "/work/$version" "$version"
done

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

# $1 tag, $2 RIFTAL_PLUGINS, $3 log file. Boots on the shared volumes, waits
# for Done, sends stop on stdin and waits for the container to exit.
boot() {
  local ref="$image:$1" log="$3" fifo="$work/stdin" i
  rm -f "$fifo"
  mkfifo "$fifo"
  docker run -i --name "$cname" -m 2g --cpus 2 --network none \
    -v "$data_vol:/data" -v "$plugins_vol:/plugins" \
    -e RIFTAL_DB_HOST=dbhost.test -e RIFTAL_DB_SCHEMA=riftal_test \
    -e RIFTAL_DB_PASSWORD_ACCOUNTS=x -e RIFTAL_DB_PASSWORD_MINES=x \
    -e RIFTAL_DB_PASSWORD_RANKS=x -e RIFTAL_DB_PASSWORD_ECONOMY=x \
    -e "RIFTAL_PLUGINS=$2" \
    -e "POCKETMINE_ARGS=--level-name=smoke_level --level-type=flat --xbox-auth=false --auto-report.enabled=0" \
    "$ref" <"$fifo" >"$log" 2>&1 &
  exec 3>"$fifo"
  for i in $(seq 1 120); do
    grep -q 'Done (' "$log" && break
    [ "$(docker inspect --format '{{.State.Running}}' "$cname" 2>/dev/null)" = false ] && break
    sleep 1
  done
  { echo stop >&3; } 2>/dev/null || true
  exec 3>&-
  timeout 90 docker wait "$cname" >/dev/null || true
  docker rm -v "$cname" >/dev/null
}

# $1 tag, $2 RIFTAL_PLUGINS, $3 version the tag's stub phars carry.
check_boot() {
  local tag="$1" plugins="$2" version="$3" log="$work/boot-$1-$$.log"
  local label want_roster got_roster want_enabled got_enabled files=(RiftalCustody.phar RiftalAccounts.phar contracts.phar) p
  for p in ${plugins//,/ }; do files+=("$p.phar"); done
  boot "$tag" "$plugins" "$log"

  label="$(docker image inspect --format '{{index .Config.Labels "org.riftal.phars"}}' "$image:$tag")"
  want_roster="$(for p in "${files[@]}"; do tr , '\n' <<<"$label" | grep "^$p=" | sed 's/^\(.*\)=\(.*\)$/\2  \1/'; done | sort)"
  got_roster="$(sed -n 's/^roster //p' "$log" | sort)"
  if [ -n "$want_roster" ] && [ "$got_roster" = "$want_roster" ]; then
    pass "$tag loaded the roster phars its label names, ${#files[@]} of them"
  else
    fail "$tag roster differs from its label. label: $want_roster / loaded: $got_roster"
  fi

  want_enabled="$(for p in "${files[@]}"; do n="${p%.phar}"; [ "$n" = contracts ] && n=RiftalContracts; echo "$n v$version"; done | sort)"
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

check_boot "$tag_n" "RiftalMines RiftalRanks RiftalEconomy" 1.0.0
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
check_boot "$tag_n" "" 1.0.0

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
