#!/usr/bin/env bash
# Self-test for restore.sh, against real, throwaway mysql:8 containers and
# real, throwaway world volumes. Runs on the self-hosted CI runner via
# `docker`, the same way ../deploy/selftest.sh and ../migrations/selftest.sh
# already do; not runnable on Nasir's Windows machine, which has no docker,
# only wslc. See ../deploy/README.md for the wslc form.
#
# This is the drill the spec requires actually be performed, not just
# documented: it backs up a database row and a world marker file, mutates
# both afterward to stand in for further play or corruption, restores from
# the backup taken before that mutation, and checks the restored row and
# file match the backup-time value, not the mutated one. A restore that
# quietly no-ops, or that merges onto drifted state instead of replacing it,
# passes a "the command exited 0" check and fails this one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX="$$-$(date +%s)"
NETWORK="riftal-restore-selftest-net-$SUFFIX"
MYSQL_CONTAINER="riftal-restore-selftest-mysql-$SUFFIX"
BACKUPS_VOL="riftal-restore-selftest-backups-$SUFFIX"
WORLD_A_VOL="riftal-restore-selftest-world-a-$SUFFIX"
WORLD_B_VOL="riftal-restore-selftest-world-b-$SUFFIX"

# Per run, so two runs sharing a host, as the self-hosted CI runners do,
# never read each other's logs.
LOGS="$(mktemp -d)"

cleanup() {
  docker rm -f "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker volume rm "$BACKUPS_VOL" "$WORLD_A_VOL" "$WORLD_B_VOL" >/dev/null 2>&1 || true
  rm -rf "$LOGS"
}
trap cleanup EXIT

docker network create "$NETWORK" >/dev/null

docker run -d --name "$MYSQL_CONTAINER" --network "$NETWORK" --network-alias mysql \
  -e MYSQL_ROOT_PASSWORD=selftest -e MYSQL_DATABASE=riftal_selftest \
  mysql:8 >/dev/null

echo "waiting for mysql to accept connections..."
ready=0
for _ in $(seq 1 60); do
  if docker exec "$MYSQL_CONTAINER" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "mysql never became ready" >&2
  exit 1
fi

query() {
  docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest -N -B "$1" -e "$2"
}
exec_sql() {
  docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest -e "$1"
}

# One row standing in for a player's balance, one marker file per world
# standing in for a specific block already broken in a specific mine, both
# named after this test rather than after the concept, so a wrong-database
# or wrong-volume restore reads as an obviously wrong value below.
exec_sql 'CREATE TABLE riftal_selftest.accounts (id INT PRIMARY KEY, balance INT);
          INSERT INTO riftal_selftest.accounts VALUES (1, 500);'
docker run --rm -v "$WORLD_A_VOL:/world" mysql:8 bash -c \
  'echo 17 > /world/blocks_broken_mine_a.txt' >/dev/null
docker run --rm -v "$WORLD_B_VOL:/world" mysql:8 bash -c \
  'echo world-b-at-backup > /world/marker.txt' >/dev/null

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=14
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

run_backup() {
  docker run --rm --network "$NETWORK" \
    -v "$SCRIPT_DIR/backup.sh:/deploy/backup.sh:ro" \
    -v "$BACKUPS_VOL:/backups" \
    -v "$WORLD_A_VOL:/worlds/world-a:ro" -v "$WORLD_B_VOL:/worlds/world-b:ro" \
    -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest \
    -e MYSQL_DATABASE=riftal_selftest -e BACKUP_RETENTION=10 \
    mysql:8 bash /deploy/backup.sh
}

run_restore() {
  local backup_set="$1"
  timeout 60 docker run --rm --network "$NETWORK" \
    -v "$SCRIPT_DIR/restore.sh:/deploy/restore.sh:ro" \
    -v "$BACKUPS_VOL:/backups:ro" \
    -v "$WORLD_A_VOL:/worlds/world-a" -v "$WORLD_B_VOL:/worlds/world-b" \
    -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest \
    -e MYSQL_DATABASE=riftal_selftest -e BACKUP_SET="$backup_set" \
    mysql:8 bash /deploy/restore.sh
}

backups() {
  docker run --rm -v "$BACKUPS_VOL:/backups" mysql:8 bash -c "$1"
}
world_a() {
  docker run --rm -v "$WORLD_A_VOL:/world" mysql:8 bash -c "$1"
}

section "a backup is taken while balance is 500 and mine_a shows 17 blocks broken"
if run_backup >"$LOGS"/out-backup.log 2>&1; then
  pass "the backup run exits 0"
else
  fail "the backup run should exit 0"; cat "$LOGS"/out-backup.log
fi
dir1="$(backups 'ls -1 /backups')"

section "the live state drifts after the backup, standing in for further play or corruption"
exec_sql 'UPDATE riftal_selftest.accounts SET balance = 999 WHERE id = 1'
world_a 'echo 999 > /world/blocks_broken_mine_a.txt; echo drift > /world/corruption.flag'
drifted_balance="$(query riftal_selftest 'SELECT balance FROM accounts WHERE id = 1')"
[ "$drifted_balance" = "999" ] && pass "the drift actually took effect before the restore is exercised" \
  || fail "expected the drifted balance 999 before restoring, got $drifted_balance"

section "restoring from the pre-drift backup set rebuilds the database and both world volumes"
if run_restore "/backups/$dir1" >"$LOGS"/out-restore.log 2>&1; then
  pass "the restore run exits 0"
else
  fail "the restore run should exit 0"; cat "$LOGS"/out-restore.log
fi

restored_balance="$(query riftal_selftest 'SELECT balance FROM accounts WHERE id = 1')"
[ "$restored_balance" = "500" ] \
  && pass "the account balance matches the backup-time value, not the drifted one" \
  || fail "expected the restored balance 500, got $restored_balance"

restored_blocks="$(world_a 'cat /world/blocks_broken_mine_a.txt')"
[ "$restored_blocks" = "17" ] \
  && pass "mine_a's broken-blocks marker matches the backup-time value, not the drifted one" \
  || fail "expected the restored marker 17, got $restored_blocks"

if world_a 'test -f /world/corruption.flag'; then
  fail "a file written to world-a after the backup should not survive a restore that rebuilds the volume"
else
  pass "the post-backup stray file is gone: the volume was rebuilt, not merged onto"
fi

restored_world_b="$(docker run --rm -v "$WORLD_B_VOL:/world" mysql:8 bash -c 'cat /world/marker.txt')"
[ "$restored_world_b" = "world-b-at-backup" ] \
  && pass "world-b's marker also matches the backup-time value, proving every world volume is rebuilt, not just one" \
  || fail "expected world-b's restored marker, got $restored_world_b"

section "a backup set with one corrupt world tar is rejected before any world directory is cleared"
# world-a sorts before world-b, so the restore loop reaches world-a first.
# Corrupting world-b's tar instead of world-a's is what actually exercises
# riftal-infra#156: a validation pass that only checked the tar it was about
# to extract would still have cleared and re-extracted world-a by the time
# it reached the corrupt one.
dir2="corrupt-$SUFFIX"
backups "cp -r /backups/$dir1 /backups/$dir2 && echo not-a-valid-gzip-archive > /backups/$dir2/worlds/world-b.tar.gz"
world_a 'echo 123 > /world/blocks_broken_mine_a.txt'
docker run --rm -v "$WORLD_B_VOL:/world" mysql:8 bash -c \
  'echo drifted-again > /world/marker.txt' >/dev/null

if run_restore "/backups/$dir2" >"$LOGS"/out-corrupt.log 2>&1; then
  fail "restoring a backup set with a corrupt world tar should exit nonzero"
else
  pass "restoring a backup set with a corrupt world tar exits nonzero"
fi
if grep -qi 'restore' "$LOGS"/out-corrupt.log; then
  pass "the corrupt-tar failure is logged, not silent"
else
  fail "expected a logged failure message for the corrupt world tar"; cat "$LOGS"/out-corrupt.log
fi

survives_a="$(world_a 'cat /world/blocks_broken_mine_a.txt')"
[ "$survives_a" = "123" ] \
  && pass "world-a, ordered ahead of the corrupt world-b tar, is untouched rather than cleared before the failure was found" \
  || fail "expected world-a's pre-restore-attempt marker 123 to survive, got $survives_a"

survives_b="$(docker run --rm -v "$WORLD_B_VOL:/world" mysql:8 bash -c 'cat /world/marker.txt')"
[ "$survives_b" = "drifted-again" ] \
  && pass "world-b, whose own tar is the corrupt one, is untouched rather than left cleared and empty" \
  || fail "expected world-b's pre-restore-attempt marker to survive, got $survives_b"

section "a restore against a backup set that does not exist fails loudly instead of silently no-op'ing"
if run_restore "/backups/no-such-set" >"$LOGS"/out-missing.log 2>&1; then
  fail "restoring a nonexistent backup set should exit nonzero"
else
  pass "restoring a nonexistent backup set exits nonzero"
fi
if grep -qi 'restore' "$LOGS"/out-missing.log; then
  pass "the failure is logged, not silent"
else
  fail "expected a logged failure message"; cat "$LOGS"/out-missing.log
fi

section "a restore leaves the database and both worlds untouched by the failed attempt"
untouched_balance="$(query riftal_selftest 'SELECT balance FROM accounts WHERE id = 1')"
[ "$untouched_balance" = "500" ] \
  && pass "the good restore from the earlier assertion is still in place after the failed attempt" \
  || fail "expected balance 500 to survive the failed restore attempt, got $untouched_balance"

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
printf 'all %s assertions passed: backup, drift, restore to the backup-time state across the database and every world volume, loud failure on a missing backup set, and loud failure on a corrupt world tar with no world directory cleared.\n' "$PASSES"
