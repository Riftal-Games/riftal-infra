#!/usr/bin/env bash
# Self-test for wipe-volumes.sh through wipe.sh, against one throwaway mysql:8
# container that publishes nothing, with two throwaway riftal_smoke_ volumes
# mounted as instance volumes. Runs under `docker`, as wipe-selftest.sh does.
#
# Each volume is seeded with the paths the wipe clears and the files it keeps
# (riftal-infra#1123). Every refusing combination of the dev predicate
# (riftal-pm#1314), and every other refusal in wipe-volumes.sh, must leave both
# volumes and the database as they were. The one passing combination must
# clear the levels, players/ and plugin_data/, and leave every kept file byte
# for byte.
#
# wipe-check.sh must fail on the seeded volumes, naming each level and folder
# the wipe clears, and pass after the wipe with every kept file still there. A
# level or a file that reappears after the wipe must fail it again.
#
# One level, mine_a on the first volume, has an ADR 009 build: a lock, and an
# output folder with a level-manifest.json. The wipe re-seeds it from that
# folder, owned by the uid of the volume's worlds/, and refuses a folder that
# does not match its lock or its own manifest. wipe-check must pass on the
# re-seeded level and fail on one that differs from the lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="$$_$(date +%s)"
C="riftal_smoke_wipevol_$TAG"
VOLUMES=("riftal_smoke_wipevol_a_$TAG" "riftal_smoke_wipevol_b_$TAG")
LOGS="$(mktemp -d)"

cleanup() {
  docker stop -t 30 "$C" >/dev/null 2>&1 || true
  # --rm removes the container a moment after it stops, and a volume it still
  # holds cannot be removed until then.
  for _ in $(seq 1 30); do
    docker volume rm "${VOLUMES[@]}" >/dev/null 2>&1 && break
    sleep 1
  done
  rm -rf "$LOGS"
}
trap cleanup EXIT

for v in "${VOLUMES[@]}"; do docker volume create "$v" >/dev/null; done
docker run -d --rm --name "$C" -m 1g --cpus 1 -v "$SCRIPT_DIR:/deploy:ro" \
  -v "$SCRIPT_DIR/../images/plugins:/images/plugins:ro" -v "${VOLUMES[0]}:/worlds/riftal_smoke_a" -v "${VOLUMES[1]}:/worlds/riftal_smoke_b" \
  -e MYSQL_ROOT_PASSWORD=selftest -e MYSQL_DATABASE=riftal_dev mysql:8 >/dev/null
for _ in $(seq 1 90); do
  docker exec "$C" mysql -uroot -pselftest -h 127.0.0.1 -e 'SELECT 1' >/dev/null 2>&1 && break
  sleep 1
done
q() { docker exec "$C" mysql -uroot -pselftest -h 127.0.0.1 -N -B -e "$1" 2>/dev/null; }
sh_in() { docker exec "$C" bash -c "$1"; }
q 'SELECT 1' >/dev/null || { echo "mysql in $C never became ready" >&2; exit 1; }

KEPT="server.log ops.txt white-list.txt banned-players.txt banned-ips.txt crashdumps/c.txt log_archive/l.log"
KEPT="$KEPT .capture/r1/players/p.dat pocketmine.yml"
sh_in "set -e; for v in a b; do d=/worlds/riftal_smoke_\$v
  mkdir -p \$d/worlds/mine_\$v/db \$d/worlds/.dot_\$v \$d/players \$d/plugin_data/RiftalMines/sub \$d/crashdumps \
    \$d/log_archive \$d/.capture/r1/players
  for f in worlds/mine_\$v/level.dat worlds/mine_\$v/db/000.ldb worlds/.dot_\$v/level.dat players/p.dat \
    plugin_data/RiftalMines/config.yml plugin_data/RiftalMines/sub/state.json $KEPT; do
    head -c 256 /dev/urandom > \$d/\$f
  done
done
mkdir -p /tmp/locks"
sh_in 'set -e; mkdir -p /tmp/built /tmp/otherlock /tmp/builds/mine_a/db
  head -c 256 /dev/urandom > /tmp/builds/mine_a/level.dat
  head -c 256 /dev/urandom > /tmp/builds/mine_a/db/000.ldb
  content=$(printf built | sha256sum | cut -d" " -f1)
  zeros=$(printf "%064d" 0)
  tree=$(cd /tmp/builds/mine_a && find . -type f ! -path ./level-manifest.json -printf "%P\0" | LC_ALL=C sort -z \
    | xargs -0 -r sha256sum -- | sha256sum | cut -d" " -f1)
  printf "{\n  \"content_sha256\": \"%s\",\n  \"tree_sha256\": \"%s\"\n}\n" "$content" "$tree" > /tmp/builds/mine_a/level-manifest.json
  printf "{\n  \"content_sha256\": \"%s\",\n  \"zone\": \"mine_a\"\n}\n" "$content" > /tmp/built/mine_a.lock.json
  printf "{\n  \"content_sha256\": \"%s\",\n  \"zone\": \"mine_a\"\n}\n" "$zeros" > /tmp/otherlock/mine_a.lock.json
  cp -r /tmp/builds /tmp/badcontent; cp -r /tmp/builds /tmp/badtree
  sed -i "s/\"content_sha256\": \"[0-9a-f]*\"/\"content_sha256\": \"$zeros\"/" /tmp/badcontent/mine_a/level-manifest.json
  printf y >> /tmp/badtree/mine_a/level.dat
  chown 1000:1000 /worlds/riftal_smoke_a/worlds'
q "CREATE TABLE riftal_dev.sentinel (id INT PRIMARY KEY); CREATE DATABASE riftal_smoke_other; CREATE DATABASE riftal"

docker exec -e MYSQL_HOST=127.0.0.1 -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest -e MYSQL_DATABASE=riftal_dev \
  -e BACKUP_ROOT=/tmp/backups -e WORLDS_DIR=/worlds "$C" bash /deploy/backup.sh >"$LOGS/backup.log" 2>&1 \
  || { cat "$LOGS/backup.log"; exit 1; }
sh_in 'set -e; sets=(/tmp/backups/[0-9]*); [ "${#sets[@]}" = 1 ]; cp -r "${sets[0]}" /tmp/set
  cp -r /tmp/set /tmp/other; sed -i "s/^mysql_database: .*/mysql_database: riftal_smoke_other/" /tmp/other/manifest.txt
  cp -r /tmp/set /tmp/rig; sed -i "s/^mysql_database: .*/mysql_database: riftal/" /tmp/rig/manifest.txt
  cp -r /tmp/set /tmp/missing; rm /tmp/missing/worlds/riftal_smoke_b.tar.gz
  cp -r /tmp/set /tmp/extra; cp /tmp/set/worlds/riftal_smoke_a.tar.gz /tmp/extra/worlds/riftal_smoke_c.tar.gz'

# Every file's hash and every directory, so any change to a volume shows.
state() { sh_in 'cd /worlds && { find . -type f -exec sha256sum {} +; find . -type d; } | sort'; }
kept() { sh_in "cd /worlds && for v in riftal_smoke_a riftal_smoke_b; do for f in $KEPT; do sha256sum \$v/\$f; done; done"; }
state >"$LOGS/state.before"
kept >"$LOGS/kept.before"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=76
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
# wipe <database> <set> [docker exec -e flags]
wipe() {
  local db="$1" set="$2"
  shift 2
  docker exec -e MYSQL_HOST=127.0.0.1 -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest -e MYSQL_DATABASE="$db" \
    -e WIPE_CONFIRM="$db" -e BACKUP_SET="$set" "$@" "$C" bash "${RUN[@]}"
}
RUN=(/deploy/wipe.sh)
refused() {
  local name="$1" reason="$2" log="$LOGS/$1.log"
  shift 2
  if wipe "$@" >"$log" 2>&1; then
    fail "$name: should be refused"; cat "$log"
  elif grep -F "refused: " "$log" | grep -qF -- "$reason"; then
    pass "$name: refused, $reason"
  else
    fail "$name: not refused for '$reason'"; cat "$log"
  fi
  if state | cmp -s - "$LOGS/state.before"; then
    pass "$name: both volumes unchanged"
  else
    fail "$name: a refused wipe changed a volume"
  fi
}
W=(-e WORLDS_DIR=/worlds)
L=(-e LEVEL_LOCKS_DIR=/tmp/locks)
DEV=(-e RIFTAL_DEV_ENV=1)
CHECK=()
check() {
  docker exec -e MYSQL_HOST=127.0.0.1 -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest -e MYSQL_DATABASE=riftal_dev \
    "${CHECK[@]}" "$C" bash /deploy/wipe-check.sh
}
# check_fails <name> <reason>...: wipe-check, run with CHECK, fails naming each.
check_fails() {
  local name="$1" log="$LOGS/check-$1.log" reason missing=
  shift
  if check >"$log" 2>&1; then
    fail "wipe-check $name: should fail"; cat "$log"; return
  fi
  for reason in "$@"; do
    grep -F "wipe-check riftal_dev: FAIL " "$log" | grep -qF -- "$reason" || missing="$reason"
  done
  if [ -z "$missing" ]; then
    pass "wipe-check $name: fails naming each of $# reason(s)"
  else
    fail "wipe-check $name: does not name '$missing'"; cat "$log"
  fi
}
NOBUILD="has no ADR 009 build and should be absent after a wipe"
BUILT="does not carry content_sha256"

printf '\n== wipe-check fails on the seeded volumes\n'
CHECK=("${W[@]}" "${L[@]}")
check_fails seeded "level mine_a on riftal_smoke_a $NOBUILD" "level .dot_a on riftal_smoke_a $NOBUILD" \
  "players/ on riftal_smoke_a holds 1 file(s)" "plugin_data/ on riftal_smoke_a holds 2 file(s)" \
  "level mine_b on riftal_smoke_b $NOBUILD" "level .dot_b on riftal_smoke_b $NOBUILD" \
  "players/ on riftal_smoke_b holds 1 file(s)" "plugin_data/ on riftal_smoke_b holds 2 file(s)"
CHECK=("${W[@]}" -e LEVEL_LOCKS_DIR=/tmp/built)
check_fails built "level mine_a on riftal_smoke_a $BUILT" "level mine_b on riftal_smoke_b $NOBUILD"
CHECK=("${L[@]}")
check_fails no-worlds-dir "WORLDS_DIR is required"
CHECK=("${W[@]}")
check_fails no-locks-dir "LEVEL_LOCKS_DIR must name a directory"
sh_in 'mkdir -p /tmp/novolumes'
CHECK=(-e WORLDS_DIR=/tmp/novolumes "${L[@]}")
check_fails no-volumes "no instance volumes found under /tmp/novolumes"
state | cmp -s - "$LOGS/state.before" && pass "wipe-check changed neither volume" \
  || fail "wipe-check changed a volume"

printf '\n== every combination but RIFTAL_DEV_ENV=1 on riftal_dev refuses a level with no build\n'
refused dev-unset "on riftal_smoke_a has no ADR 009 build, and a wipe clears one only on the dev stack: RIFTAL_DEV_ENV is unset" \
  riftal_dev /tmp/set "${W[@]}" "${L[@]}"
refused dev-empty "only on the dev stack: RIFTAL_DEV_ENV is empty" \
  riftal_dev /tmp/set "${W[@]}" "${L[@]}" -e RIFTAL_DEV_ENV=
refused dev-true "only on the dev stack: RIFTAL_DEV_ENV is 'true', not 1" \
  riftal_dev /tmp/set "${W[@]}" "${L[@]}" -e RIFTAL_DEV_ENV=true
refused dev-zero "only on the dev stack: RIFTAL_DEV_ENV is '0', not 1" \
  riftal_dev /tmp/set "${W[@]}" "${L[@]}" -e RIFTAL_DEV_ENV=0
refused dev-other-db "only on the dev stack: RIFTAL_DEV_ENV is 1 against database riftal_smoke_other, not riftal_dev" \
  riftal_smoke_other /tmp/other "${W[@]}" "${L[@]}" "${DEV[@]}"
refused dev-rig-db "only on the dev stack: RIFTAL_DEV_ENV is 1 against database riftal, not riftal_dev" \
  riftal /tmp/rig "${W[@]}" "${L[@]}" "${DEV[@]}"

printf '\n== on dev, every other refusal\n'
B=(-e LEVEL_LOCKS_DIR=/tmp/built)
refused built-no-builds-dir "level mine_a on riftal_smoke_a has an ADR 009 build to re-seed from, and LEVEL_BUILDS_DIR must hold its output folder mine_a" \
  riftal_dev /tmp/set "${W[@]}" "${B[@]}" "${DEV[@]}"
refused built-content-differs "/tmp/badcontent/mine_a/level-manifest.json does not carry content_sha256" \
  riftal_dev /tmp/set "${W[@]}" "${B[@]}" -e LEVEL_BUILDS_DIR=/tmp/badcontent "${DEV[@]}"
refused built-tree-differs "the file tree of /tmp/badtree/mine_a is not the one its level-manifest.json names" \
  riftal_dev /tmp/set "${W[@]}" "${B[@]}" -e LEVEL_BUILDS_DIR=/tmp/badtree "${DEV[@]}"
sh_in 'chown 0:0 /worlds/riftal_smoke_a/worlds'
refused built-worlds-root-owned "/worlds/riftal_smoke_a/worlds is owned by root, so core could not write the re-seeded level mine_a" \
  riftal_dev /tmp/set "${W[@]}" "${B[@]}" -e LEVEL_BUILDS_DIR=/tmp/builds "${DEV[@]}"
sh_in 'chown 1000:1000 /worlds/riftal_smoke_a/worlds'
refused no-worlds-dir "WORLDS_DIR is required" riftal_dev /tmp/set "${L[@]}" "${DEV[@]}"
refused no-locks-dir "LEVEL_LOCKS_DIR must name a directory" riftal_dev /tmp/set "${W[@]}" "${DEV[@]}"
refused absent-locks-dir "LEVEL_LOCKS_DIR must name a directory" \
  riftal_dev /tmp/set "${W[@]}" -e LEVEL_LOCKS_DIR=/tmp/nowhere "${DEV[@]}"
refused volume-not-in-set "/tmp/missing holds no riftal_smoke_b.tar.gz, so restore.sh could not roll volume riftal_smoke_b back" \
  riftal_dev /tmp/missing "${W[@]}" "${L[@]}" "${DEV[@]}"
refused set-volume-not-mounted "/tmp/extra/worlds/riftal_smoke_c.tar.gz has no volume under /worlds" \
  riftal_dev /tmp/extra "${W[@]}" "${L[@]}" "${DEV[@]}"
# Run by hand, every key the wipe reads set as on dev, it still clears nothing:
# its checks are wipe.sh's, and the dev verdict is wipe.sh's alone.
RUN=(/deploy/wipe-volumes.sh dev)
refused direct "wipe-volumes.sh runs only inside wipe.sh" \
  riftal_dev /tmp/set "${W[@]}" "${L[@]}" "${DEV[@]}"
RUN=(/deploy/wipe.sh)
[ "$(q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'riftal_dev'")" = "1" ] \
  && pass "every refusal left riftal_dev in place" || fail "a refused wipe changed riftal_dev"

printf '\n== RIFTAL_DEV_ENV=1 on riftal_dev clears the ruled paths and keeps the rest\n'
if wipe riftal_dev /tmp/set "${W[@]}" "${B[@]}" -e LEVEL_BUILDS_DIR=/tmp/builds "${DEV[@]}" >"$LOGS/wipe.log" 2>&1; then
  pass "the dev wipe exits 0"
else
  fail "the dev wipe should exit 0"; cat "$LOGS/wipe.log"
fi
for v in a b; do
  grep -qx "wipe riftal_dev: volume riftal_smoke_$v: cleared 2 level(s) and the contents of players/ and plugin_data/" \
    "$LOGS/wipe.log" && pass "riftal_smoke_$v: the wipe reports 2 levels cleared" \
    || fail "riftal_smoke_$v: the wipe does not report 2 levels cleared"
  [ "$(sh_in "ls -A /worlds/riftal_smoke_$v/worlds")" = "$([ "$v" = a ] && echo mine_a)" ] \
    && pass "riftal_smoke_$v: no level folder is left but the re-seeded one, dotted ones included" \
    || fail "riftal_smoke_$v: a level folder survived or the re-seeded one is missing"
  for dir in players plugin_data; do
    [ "$(sh_in "[ -d /worlds/riftal_smoke_$v/$dir ] && ls -A /worlds/riftal_smoke_$v/$dir | wc -l")" = "0" ] \
      && pass "riftal_smoke_$v: $dir/ is there and empty" || fail "riftal_smoke_$v: $dir/ is missing or not empty"
  done
done
grep -qx "wipe riftal_dev: volume riftal_smoke_a: re-seeded level mine_a from /tmp/builds/mine_a" "$LOGS/wipe.log" \
  && pass "the wipe reports mine_a re-seeded from its build" || fail "the wipe does not report mine_a re-seeded"
sums() { sh_in "cd $1 && find . -type f -exec sha256sum {} + | sort"; }
[ "$(sums /tmp/builds/mine_a)" = "$(sums /worlds/riftal_smoke_a/worlds/mine_a)" ] \
  && pass "the re-seeded mine_a is the build, file for file" || fail "the re-seeded mine_a differs from its build"
[ "$(sh_in 'find /worlds/riftal_smoke_a/worlds/mine_a ! -user 1000 | wc -l')" = "0" ] \
  && pass "everything in the re-seeded mine_a is owned by the uid of worlds/" || fail "the re-seeded mine_a holds a file not owned by 1000"
kept >"$LOGS/kept.after"
while read -r sum path; do
  grep -qxF "$sum  $path" "$LOGS/kept.after" && pass "kept byte for byte: $path" || fail "changed or gone: $path"
done <"$LOGS/kept.before"
[ "$(q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'riftal_dev'")" = "0" ] \
  && pass "riftal_dev is there and empty" || fail "riftal_dev should be there and empty"

printf '\n== after the wipe, wipe-check passes with every kept file still there\n'
# Stands in for the migrations, which wipe-selftest.sh runs, so the database
# half of wipe-check passes and only the volumes decide it. A migrated schema
# holds an empty table besides schema_migrations, and wipe-check refuses one
# that lists none.
q "CREATE TABLE riftal_dev.schema_migrations (version INT PRIMARY KEY); INSERT INTO riftal_dev.schema_migrations VALUES (1)
  ; CREATE TABLE riftal_dev.migrated (id INT PRIMARY KEY)"
CHECK=("${W[@]}" "${B[@]}")
if check >"$LOGS/check-wiped.log" 2>&1; then
  pass "wipe-check passes on the wiped volumes"
else
  fail "wipe-check should pass on the wiped volumes"; cat "$LOGS/check-wiped.log"
fi
HELD_A="level(s) mine_a match their lock's content_sha256"
for v in a b; do
  held="no level"
  [ "$v" = a ] && held="$HELD_A"
  grep -qx "wipe-check riftal_dev: volume riftal_smoke_$v: ok, $held, and players/ and plugin_data/ hold no file" \
    "$LOGS/check-wiped.log" && pass "riftal_smoke_$v: wipe-check reports the volume ok" \
    || fail "riftal_smoke_$v: wipe-check does not report the volume ok"
done
CHECK=("${W[@]}" -e LEVEL_LOCKS_DIR=/tmp/otherlock)
check_fails other-lock "level mine_a on riftal_smoke_a $BUILT 0000000000000000000000000000000000000000000000000000000000000000"
sh_in 'set -e; mkdir -p /worlds/riftal_smoke_a/worlds/mine_a /worlds/riftal_smoke_b/plugin_data/RiftalMines/sub
  printf x > /worlds/riftal_smoke_a/worlds/mine_a/level.dat
  printf x > /worlds/riftal_smoke_b/plugin_data/RiftalMines/sub/state.json'
CHECK=("${W[@]}" "${L[@]}")
check_fails regrown "level mine_a on riftal_smoke_a $NOBUILD" "plugin_data/ on riftal_smoke_b holds 1 file(s)"
CHECK=("${W[@]}" "${B[@]}")
check_fails regrown-built "level mine_a on riftal_smoke_a has a file tree that is not the one its level-manifest.json names"

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed\n' "$PASSES"
