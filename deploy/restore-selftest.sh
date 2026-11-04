#!/usr/bin/env bash
# Self-test for restore.sh, against a real, throwaway mysql:8 container and
# real, throwaway world volumes. restore.sh itself runs in a build of
# ../images/backup, because it tests server.lock with flock, which mysql:8
# does not carry. Calls `docker` directly, as
# ../deploy/selftest.sh and ../migrations/selftest.sh do, so it runs on the
# self-hosted CI runner and, on Nasir's Windows machine, under the WSL
# fallback engine:
#   wsl -d Ubuntu-26.04 -u runner --exec bash /mnt/c/.../deploy/restore-selftest.sh
# ../deploy/README.md shows a manual restore run under wslc.
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
RESTORE_CONTAINER="riftal_smoke_restore_restore_$SUFFIX"
BACKUPS_VOL="riftal_smoke_restore_backups_$SUFFIX"
WORLD_A_VOL="riftal_smoke_restore_world_a_$SUFFIX"
WORLD_B_VOL="riftal_smoke_restore_world_b_$SUFFIX"
BACKUP_PW=selftestPasswordBackupLogin01
RESTORE_IMG="riftal_smoke_restore_img:$SUFFIX"

# Per run, so two runs sharing a host, as the self-hosted CI runners do,
# never read each other's logs.
LOGS="$(mktemp -d)"

cleanup() {
  docker rm -f -v "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f -v "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker volume rm "$BACKUPS_VOL" "$WORLD_A_VOL" "$WORLD_B_VOL" >/dev/null 2>&1 || true
  docker image rm "$RESTORE_IMG" >/dev/null 2>&1 || true
  rm -rf "$LOGS"
}
trap cleanup EXIT

docker build -q -t "$RESTORE_IMG" "$SCRIPT_DIR/../images/backup" >/dev/null
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
# restore.sh drops the database, and its procedures, triggers and views with
# it, so these exist after the restore only if backup.sh dumped them, which the
# backup login can do only through SHOW_ROUTINE, TRIGGER and SHOW VIEW.
exec_sql 'CREATE PROCEDURE riftal_selftest.balance_of_1()
          SELECT balance FROM riftal_selftest.accounts WHERE id = 1'
exec_sql 'CREATE TRIGGER riftal_selftest.accounts_no_negative BEFORE INSERT
          ON riftal_selftest.accounts FOR EACH ROW
          SET NEW.balance = GREATEST(NEW.balance, 0)'
exec_sql 'CREATE VIEW riftal_selftest.account_balances AS
          SELECT id, balance FROM riftal_selftest.accounts'
docker exec -i "$MYSQL_CONTAINER" mysql -uroot -pselftest riftal_selftest <"$SCRIPT_DIR/fence-fixture.sql"
docker exec -i "$MYSQL_CONTAINER" mysql -uroot -pselftest riftal_selftest <"$SCRIPT_DIR/fence-listing-fixture.sql"
docker run --rm -m 1g --cpus 1 -v "$WORLD_A_VOL:/world" mysql:8 bash -c \
  'echo 17 > /world/blocks_broken_mine_a.txt' >/dev/null
docker run --rm -m 1g --cpus 1 -v "$WORLD_B_VOL:/world" mysql:8 bash -c \
  'echo world-b-at-backup > /world/marker.txt' >/dev/null

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=44
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

# The docker client forwards timeout's SIGTERM to restore.sh's bash, which as
# PID 1 ignores it, so only the SIGKILL from -k ends the client, and that
# leaves the container running. Removing it by name is what frees the runner.
run_restore() {
  local backup_set="$1" user="${2:-root}" rc=0
  timeout -k 5 60 docker run --rm -m 1g --cpus 1 --name "$RESTORE_CONTAINER" --network "$NETWORK" \
    -v "${RESTORE_SCRIPT:-$SCRIPT_DIR/restore.sh}:/deploy/restore.sh:ro" \
    -e ALLOW_UNFENCED_SET="${ALLOW_UNFENCED_SET:-}" -e ALLOW_UNCAPTURED_SET="${ALLOW_UNCAPTURED_SET:-}" \
    -v "$BACKUPS_VOL:/backups:ro" \
    -v "$WORLD_A_VOL:/worlds/world-a" -v "$WORLD_B_VOL:/worlds/world-b" \
    -e MYSQL_HOST=mysql -e MYSQL_USER="$user" -e MYSQL_PASSWORD=selftest \
    -e MYSQL_DATABASE=riftal_selftest -e BACKUP_SET="$backup_set" \
    "$RESTORE_IMG" bash -c "${RESTORE_PRELUDE:-}bash /deploy/restore.sh" || rc=$?
  docker rm -f -v "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
  return "$rc"
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
# riftal-game's grants.sql gives the role these; the runner here applies no grants file.
exec_sql 'GRANT EXECUTE ON PROCEDURE riftal_selftest.capture_fence_raise TO riftal_role_backup;
          GRANT EXECUTE ON PROCEDURE riftal_selftest.capture_fence_lower TO riftal_role_backup'
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

restored_view="$(query riftal_selftest 'SELECT balance FROM account_balances WHERE id = 1' 2>"$LOGS"/out-view.log || true)"
if [ "$restored_view" = "500" ]; then
  pass "a view survives a backup taken by the backup login and still reads the restored row"
else
  fail "expected account_balances to return 500 after a restore from the backup login's dump, got '$restored_view'"
  cat "$LOGS"/out-view.log
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

section "a restore is refused while another session is connected, or without PROCESS, and changes nothing"
exec_sql 'UPDATE riftal_selftest.accounts SET balance = 777 WHERE id = 1'
world_a 'echo 777 > /world/blocks_broken_mine_a.txt'
# An account with every privilege on the schema but no PROCESS sees only its
# own threads in the processlist, so it would count 0 with a session connected.
exec_sql "CREATE USER 'restorer'@'%' IDENTIFIED BY 'selftest'; GRANT ALL ON riftal_selftest.* TO 'restorer'@'%'"
# Tagged so the session is found by its own text and never by another's.
docker exec -d "$MYSQL_CONTAINER" mysql -uroot -pselftest -e 'SELECT SLEEP(600) AS riftal_selftest_held'
held=0
for _ in $(seq 1 20); do
  held="$(query riftal_selftest "SELECT COUNT(*) FROM performance_schema.processlist WHERE INFO LIKE 'SELECT SLEEP(% AS riftal_selftest_held'")"
  [ "$held" = "1" ] && break
  sleep 0.5
done
if [ "$held" != "1" ]; then
  echo "the session meant to stay connected never appeared in the processlist" >&2
  exit 1
fi

refused_unchanged() {
  local label="$1" pattern="$2" user="$3" set="${4:-/backups/$dir1}" balance marker
  if run_restore "$set" "$user" >"$LOGS/out-$label.log" 2>&1; then
    fail "$label: the restore should exit nonzero"
  elif grep -q "$pattern" "$LOGS/out-$label.log"; then
    pass "$label: refused with '$pattern'"
  else
    fail "$label: expected '$pattern' in the refusal"; cat "$LOGS/out-$label.log"
  fi
  balance="$(query riftal_selftest 'SELECT balance FROM accounts WHERE id = 1' 2>/dev/null || true)"
  marker="$(world_a 'cat /world/blocks_broken_mine_a.txt')"
  if [ "$balance" = "777" ] && [ "$marker" = "777" ]; then
    pass "$label: the database and the world volume are as they were"
  else
    fail "$label: expected balance 777 and marker 777 untouched, got '$balance' and '$marker'"
  fi
}
refused_unchanged connected-session "other session(s) are connected" root
refused_unchanged no-process "lacks PROCESS" restorer

held_id="$(query riftal_selftest "SELECT ID FROM performance_schema.processlist WHERE INFO LIKE 'SELECT SLEEP(% AS riftal_selftest_held'")"
case "$held_id" in
  '' | *[!0-9]*) echo "the held session's id read '$held_id'" >&2; exit 1 ;;
esac
exec_sql "KILL $held_id"
for _ in $(seq 1 30); do
  [ "$(query riftal_selftest "SELECT COUNT(*) FROM performance_schema.processlist WHERE INFO LIKE 'SELECT SLEEP(% AS riftal_selftest_held'")" = "0" ] && break
  sleep 0.5
done
# The same set restores once the session is gone, so the refusals above came
# from the session and the account, not from the set.
if run_restore "/backups/$dir1" >"$LOGS"/out-released.log 2>&1 \
  && [ "$(query riftal_selftest 'SELECT balance FROM accounts WHERE id = 1')" = "500" ]; then
  pass "with the session gone, the same set restores to the backup-time balance"
else
  fail "expected the restore to succeed once the held session ended"; cat "$LOGS"/out-released.log
fi

section "a restored fence row is lowered, and a set with no capture_fence line is refused unless allowed"
fence_lowered() { query riftal_selftest 'SELECT request_id IS NULL AND raised_until IS NULL FROM capture_fence WHERE id = 1'; }
fence_collect() { query riftal_selftest 'CALL fixture_listing_collect(1, "restore-check", @o); SELECT @o'; }

# The dump holds the row raised for 1800 s from the run that took it, so a
# restore that does not lower it leaves every commit-first flow fenced.
keeps_fence="$LOGS/restore-keeps-fence.sh"
sed 's/^if \[ "\$fenced" = 1 \]; then$/if false; then/' "$SCRIPT_DIR/restore.sh" >"$keeps_fence"
if [ "$(diff "$SCRIPT_DIR/restore.sh" "$keeps_fence" | grep -c '^<' || true)" != "1" ]; then
  echo "the keeps-fence mutant did not change exactly one line of restore.sh" >&2
  exit 1
fi
if RESTORE_SCRIPT="$keeps_fence" run_restore "/backups/$dir1" >"$LOGS"/out-keeps-fence.log 2>&1; then
  pass "mutant: with the lower removed the restore still exits 0"
else
  fail "the keeps-fence mutant should restore"; cat "$LOGS"/out-keeps-fence.log
fi
[ "$(fence_lowered)" = "0" ] \
  && pass "mutant: the fence row is left raised, the lease of a run that no longer exists" \
  || fail "expected the keeps-fence mutant to leave the row raised, got '$(fence_lowered)'"
[ "$(fence_collect)" = "capture_fenced" ] \
  && pass "mutant: a commit-first collect answers capture_fenced" \
  || fail "expected capture_fenced from the keeps-fence mutant, got '$(fence_collect)'"

if run_restore "/backups/$dir1" >"$LOGS"/out-lowered.log 2>&1; then
  pass "a fenced set restores inside its lease"
else
  fail "the fenced set should restore"; cat "$LOGS"/out-lowered.log
fi
[ "$(fence_lowered)" = "1" ] \
  && pass "the restored fence row is lowered" \
  || fail "expected the restored fence row lowered, got '$(fence_lowered)'"
[ "$(fence_collect)" = "collected" ] \
  && pass "a commit-first collect commits at once" \
  || fail "expected collected after the restore, got '$(fence_collect)'"

dir3="unfenced-$SUFFIX"
backups "cp -r /backups/$dir1 /backups/$dir3 && sed -i '/^capture_fence:/d' /backups/$dir3/manifest.txt \
  && test \"\$(grep -c '^capture_fence:' /backups/$dir3/manifest.txt)\" = 0"
exec_sql 'UPDATE riftal_selftest.accounts SET balance = 777 WHERE id = 1'
world_a 'echo 777 > /world/blocks_broken_mine_a.txt'
refused_unchanged unfenced-set "no capture_fence line" root "/backups/$dir3"
if ALLOW_UNFENCED_SET=1 run_restore "/backups/$dir3" >"$LOGS"/out-allowed.log 2>&1 \
  && [ "$(query riftal_selftest 'SELECT balance FROM accounts WHERE id = 1')" = "500" ]; then
  pass "with ALLOW_UNFENCED_SET=1 the same set restores to the backup-time balance"
else
  fail "expected the unfenced set to restore with ALLOW_UNFENCED_SET=1"; cat "$LOGS"/out-allowed.log
fi

section "a set with no capture mode for some volume is refused unless allowed, and a held server.lock is refused"
[ "$(backups "grep -c '^capture_mode\\.world-[ab]: ' /backups/$dir1/manifest.txt")" = "2" ] \
  && pass "the set the earlier restores used records a mode for both volumes, so it restored with no override" \
  || fail "expected backup.sh to record a capture_mode line for both volumes"
exec_sql 'UPDATE riftal_selftest.accounts SET balance = 777 WHERE id = 1'
world_a 'echo 777 > /world/blocks_broken_mine_a.txt'

dir4="uncaptured-$SUFFIX"
dir5="one-mode-$SUFFIX"
dir6="no-manifest-$SUFFIX"
backups "cp -r /backups/$dir1 /backups/$dir4 && sed -i '/^capture_mode\\./d' /backups/$dir4/manifest.txt \
  && cp -r /backups/$dir1 /backups/$dir5 && sed -i '/^capture_mode\\.world-b:/d' /backups/$dir5/manifest.txt \
  && cp -r /backups/$dir1 /backups/$dir6 && rm /backups/$dir6/manifest.txt"
refused_unchanged uncaptured-set "no valid capture_mode line" root "/backups/$dir4"
refused_unchanged one-volume-mode "no valid capture_mode line" root "/backups/$dir5"
refused_unchanged no-manifest "no valid capture_mode line" root "/backups/$dir6"
if ALLOW_UNCAPTURED_SET=1 run_restore "/backups/$dir4" >"$LOGS"/out-uncaptured-allowed.log 2>&1 \
  && grep -q 'WARNING: ALLOW_UNCAPTURED_SET=1' "$LOGS"/out-uncaptured-allowed.log \
  && [ "$(query riftal_selftest 'SELECT balance FROM accounts WHERE id = 1')" = "500" ]; then
  pass "with ALLOW_UNCAPTURED_SET=1 the uncaptured set restores to the backup-time balance and warns"
else
  fail "expected the uncaptured set to restore with a warning under ALLOW_UNCAPTURED_SET=1"; cat "$LOGS"/out-uncaptured-allowed.log
fi

exec_sql 'UPDATE riftal_selftest.accounts SET balance = 777 WHERE id = 1'
world_a 'echo 777 > /world/blocks_broken_mine_a.txt'
# A shared flock on a descriptor of its own, as core holds server.lock while it runs.
RESTORE_PRELUDE='exec 9>>/worlds/world-a/server.lock; flock -s 9; '
refused_unchanged held-lock "server.lock of volume world-a is held" root
RESTORE_PRELUDE=

# A set taken from a held volume carries the server.lock core held at the tick.
dir7="stale-lock-$SUFFIX"
backups "cp -r /backups/$dir1 /backups/$dir7 && d=\$(mktemp -d) && tar -xzf /backups/$dir7/worlds/world-a.tar.gz -C \$d \
  && echo from-the-set > \$d/server.lock && tar -czf /backups/$dir7/worlds/world-a.tar.gz -C \$d . && rm -rf \$d"
if run_restore "/backups/$dir7" >"$LOGS"/out-stale-lock.log 2>&1 \
  && [ "$(query riftal_selftest 'SELECT balance FROM accounts WHERE id = 1')" = "500" ]; then
  pass "a volume whose server.lock is free restores to the backup-time balance"
else
  fail "expected a free server.lock not to refuse the restore"; cat "$LOGS"/out-stale-lock.log
fi
if world_a 'test -f /world/server.lock && ! grep -q from-the-set /world/server.lock'; then
  pass "the volume's own server.lock was kept, not replaced by the one in the tar"
else
  fail "expected the volume's server.lock to survive the extract unreplaced"
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
printf 'all %s assertions passed: backup by the backup login, drift, restore to the backup-time state across the database, its stored procedures, triggers and views and every world volume, loud failure on a missing backup set, loud failure on a corrupt world tar with no world directory cleared, and refusal, with nothing changed, while another session is connected or when the account lacks PROCESS, the restored capture fence row lowered so a commit-first collect commits at once, and refusal, with nothing changed, of a set whose manifest has no capture_fence line unless ALLOW_UNFENCED_SET=1, and refusal, with nothing changed, of a set with no valid capture_mode line for every volume unless ALLOW_UNCAPTURED_SET=1, and of a volume whose server.lock is held, with a free server.lock kept through the extract.\n' "$PASSES"
