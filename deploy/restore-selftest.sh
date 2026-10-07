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
# riftal_smoke_ names, because the guard lets a volume be removed only under
# that prefix, so this runs and cleans up the same on a dev machine as in CI.
NETWORK="riftal_smoke_restore_net_$SUFFIX"
MYSQL_CONTAINER="riftal_smoke_restore_mysql_$SUFFIX"
BACKUPS_VOL="riftal_smoke_restore_backups_$SUFFIX"
WORLD_A_VOL="riftal_smoke_restore_world_a_$SUFFIX"
WORLD_B_VOL="riftal_smoke_restore_world_b_$SUFFIX"
BACKUP_PW=selftestPasswordBackupLogin01

# Per run, so two runs sharing a host, as the self-hosted CI runners do,
# never read each other's logs.
LOGS="$(mktemp -d)"

cleanup() {
  docker rm -f -v "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker volume rm "$BACKUPS_VOL" "$WORLD_A_VOL" "$WORLD_B_VOL" >/dev/null 2>&1 || true
  rm -rf "$LOGS"
}
trap cleanup EXIT

docker network create "$NETWORK" >/dev/null
# Created before any `run -v` names them, so CI's label shim stamps them for
# the job's sweep, which is all that removes them when a cancel skips the trap.
docker volume create "$BACKUPS_VOL" >/dev/null
docker volume create "$WORLD_A_VOL" >/dev/null
docker volume create "$WORLD_B_VOL" >/dev/null

docker run -d --rm -m 1g --cpus 1 --name "$MYSQL_CONTAINER" --network "$NETWORK" --network-alias mysql \
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
# restore.sh drops the database, and its procedures and triggers with it, so
# these exist after the restore only if backup.sh dumped them, which the
# backup login can do only through SHOW_ROUTINE and TRIGGER.
exec_sql 'CREATE PROCEDURE riftal_selftest.balance_of_1()
          SELECT balance FROM riftal_selftest.accounts WHERE id = 1'
exec_sql 'CREATE TRIGGER riftal_selftest.accounts_no_negative BEFORE INSERT
          ON riftal_selftest.accounts FOR EACH ROW
          SET NEW.balance = GREATEST(NEW.balance, 0)'
docker run --rm -m 1g --cpus 1 -v "$WORLD_A_VOL:/world" mysql:8 bash -c \
  'echo 17 > /world/blocks_broken_mine_a.txt' >/dev/null
docker run --rm -m 1g --cpus 1 -v "$WORLD_B_VOL:/world" mysql:8 bash -c \
  'echo world-b-at-backup > /world/marker.txt' >/dev/null

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=17
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

run_backup() {
  docker run --rm -m 1g --cpus 1 --network "$NETWORK" \
    -v "$SCRIPT_DIR/backup.sh:/deploy/backup.sh:ro" \
    -v "$BACKUPS_VOL:/backups" \
    -v "$WORLD_A_VOL:/worlds/world-a:ro" -v "$WORLD_B_VOL:/worlds/world-b:ro" \
    -e MYSQL_HOST=mysql -e MYSQL_PASSWORD="$BACKUP_PW" \
    -e MYSQL_DATABASE=riftal_selftest -e BACKUP_RETENTION=10 \
    mysql:8 bash /deploy/backup.sh
}

provision_backup_login() {
  docker run --rm -m 1g --cpus 1 --network "$NETWORK" \
    -v "$SCRIPT_DIR/../migrations/run-migrations.sh:/run-migrations.sh:ro" \
    -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest \
    -e MYSQL_DATABASE=riftal_selftest -e MIGRATIONS_DIR=/missing \
    -e RIFTAL_DB_PASSWORD_BACKUP="$BACKUP_PW" \
    mysql:8 bash /run-migrations.sh
}

run_restore() {
  local backup_set="$1"
  timeout 60 docker run --rm -m 1g --cpus 1 --network "$NETWORK" \
    -v "$SCRIPT_DIR/restore.sh:/deploy/restore.sh:ro" \
    -v "$BACKUPS_VOL:/backups:ro" \
    -v "$WORLD_A_VOL:/worlds/world-a" -v "$WORLD_B_VOL:/worlds/world-b" \
    -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest \
    -e MYSQL_DATABASE=riftal_selftest -e BACKUP_SET="$backup_set" \
    mysql:8 bash /deploy/restore.sh
}

backups() {
  docker run --rm -m 1g --cpus 1 -v "$BACKUPS_VOL:/backups" mysql:8 bash -c "$1"
}
world_a() {
  docker run --rm -m 1g --cpus 1 -v "$WORLD_A_VOL:/world" mysql:8 bash -c "$1"
}

section "a backup is taken by the backup login while balance is 500 and mine_a shows 17 blocks broken"
if provision_backup_login >"$LOGS"/out-provision.log 2>&1; then
  pass "the migration runner provisions the backup login"
else
  fail "the migration runner should provision the backup login"; cat "$LOGS"/out-provision.log
fi
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

restored_call="$(query riftal_selftest 'CALL balance_of_1()' 2>"$LOGS"/out-call.log || true)"
if [ "$restored_call" = "500" ]; then
  pass "a stored procedure survives a backup taken by the backup login and still runs"
else
  fail "expected CALL balance_of_1() to return 500 after a restore from the backup login's dump, got '$restored_call'"
  cat "$LOGS"/out-call.log
fi

restored_trigger="$(query riftal_selftest "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='riftal_selftest'")"
if [ "$restored_trigger" = "accounts_no_negative" ]; then
  pass "a trigger survives a backup taken by the backup login"
else
  fail "expected trigger accounts_no_negative after a restore from the backup login's dump, got '$restored_trigger'"
fi

restored_blocks="$(world_a 'cat /world/blocks_broken_mine_a.txt')"
[ "$restored_blocks" = "17" ] \
  && pass "mine_a's broken-blocks marker matches the backup-time value, not the drifted one" \
  || fail "expected the restored marker 17, got $restored_blocks"

if world_a 'test -f /world/corruption.flag'; then
  fail "a file written to world-a after the backup should not survive a restore that rebuilds the volume"
else
  pass "the post-backup stray file is gone: the volume was rebuilt, not merged onto"
fi

restored_world_b="$(docker run --rm -m 1g --cpus 1 -v "$WORLD_B_VOL:/world" mysql:8 bash -c 'cat /world/marker.txt')"
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
docker run --rm -m 1g --cpus 1 -v "$WORLD_B_VOL:/world" mysql:8 bash -c \
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

survives_b="$(docker run --rm -m 1g --cpus 1 -v "$WORLD_B_VOL:/world" mysql:8 bash -c 'cat /world/marker.txt')"
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
printf 'all %s assertions passed: backup by the backup login, drift, restore to the backup-time state across the database, its stored procedures and triggers and every world volume, loud failure on a missing backup set, and loud failure on a corrupt world tar with no world directory cleared.\n' "$PASSES"
