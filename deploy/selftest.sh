#!/usr/bin/env bash
# Self-test for backup.sh, against a real, throwaway mysql:8 container and
# real, throwaway world volumes. Runs on the self-hosted CI runner via
# `docker`, the same way ../migrations/selftest.sh already does; not runnable
# on Nasir's Windows machine, which has no docker, only wslc. See
# ../deploy/README.md for the wslc form.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX="$$-$(date +%s)"
NETWORK="riftal-backup-selftest-net-$SUFFIX"
MYSQL_CONTAINER="riftal-backup-selftest-mysql-$SUFFIX"
BACKUPS_VOL="riftal-backup-selftest-backups-$SUFFIX"
WORLD_A_VOL="riftal-backup-selftest-world-a-$SUFFIX"
WORLD_B_VOL="riftal-backup-selftest-world-b-$SUFFIX"

cleanup() {
  docker rm -f "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker volume rm "$BACKUPS_VOL" "$WORLD_A_VOL" "$WORLD_B_VOL" >/dev/null 2>&1 || true
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
docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest riftal_selftest -e \
  'CREATE TABLE marker (id INT PRIMARY KEY, note VARCHAR(64));
   INSERT INTO marker VALUES (1, "backup-selftest-marker");' >/dev/null

docker run --rm -v "$WORLD_A_VOL:/world" mysql:8 bash -c \
  'echo world-a-marker > /world/marker.txt' >/dev/null
docker run --rm -v "$WORLD_B_VOL:/world" mysql:8 bash -c \
  'echo world-b-marker > /world/marker.txt' >/dev/null

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=33
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

# Any argument past the first 5 is forwarded to backup.sh itself, so a
# caller can drive its __test_acquire_lock / __test_release_lock entry
# points (riftal-infra#173) instead of always running the full script.
run_backup() {
  local retention="$1" host="$2" password="$3" partial_max_age="${4:-360}" lock_max_age="${5:-90}"
  if [ "$#" -gt 5 ]; then shift 5; else shift "$#"; fi
  timeout 60 docker run --rm --network "$NETWORK" \
    -v "$SCRIPT_DIR/backup.sh:/deploy/backup.sh:ro" \
    -v "$BACKUPS_VOL:/backups" \
    -v "$WORLD_A_VOL:/worlds/world-a:ro" -v "$WORLD_B_VOL:/worlds/world-b:ro" \
    -e MYSQL_HOST="$host" -e MYSQL_USER=root -e MYSQL_PASSWORD="$password" \
    -e MYSQL_DATABASE=riftal_selftest -e BACKUP_RETENTION="$retention" \
    -e PARTIAL_MAX_AGE_MINUTES="$partial_max_age" -e LOCK_MAX_AGE_MINUTES="$lock_max_age" \
    -e STEAL_RACE_TEST_STALL_SECONDS="${STEAL_RACE_TEST_STALL_SECONDS:-0}" \
    mysql:8 bash /deploy/backup.sh "$@"
}

backups() {
  docker run --rm -v "$BACKUPS_VOL:/backups" mysql:8 bash -c "$1"
}

section "a run captures a restorable, coordinated dump and world snapshots"
if run_backup 10 mysql selftest >/tmp/out-run1.log 2>&1; then
  pass "first run exits 0"
else
  fail "first run should exit 0"; cat /tmp/out-run1.log
fi

set_count="$(backups 'ls -1 /backups | wc -l')"
[ "$set_count" = "1" ] && pass "exactly one backup set after one run" \
  || fail "expected 1 backup set, got $set_count"

dir1="$(backups 'ls -1 /backups')"
if backups "test -s /backups/$dir1/mysql.sql && \
  test -s /backups/$dir1/worlds/world-a.tar.gz && \
  test -s /backups/$dir1/worlds/world-b.tar.gz && \
  test -s /backups/$dir1/manifest.txt"; then
  pass "dump, both world tars, and the manifest are all present and non-empty"
else
  fail "one or more expected artifacts is missing or empty"
fi

docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest -e \
  'CREATE DATABASE IF NOT EXISTS riftal_selftest_restore' >/dev/null
backups "cat /backups/$dir1/mysql.sql" | \
  docker exec -i "$MYSQL_CONTAINER" mysql -uroot -pselftest riftal_selftest_restore
restored_note="$(docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest -N -B \
  riftal_selftest_restore -e 'SELECT note FROM marker WHERE id = 1')"
[ "$restored_note" = "backup-selftest-marker" ] \
  && pass "the mysqldump loads into a fresh database with the marker row intact" \
  || fail "expected the restored marker row, got '$restored_note'"

extracted="$(backups "mkdir -p /tmp/x && tar -xzf /backups/$dir1/worlds/world-a.tar.gz -C /tmp/x && cat /tmp/x/marker.txt")"
[ "$extracted" = "world-a-marker" ] \
  && pass "the world tar extracts back into a usable world directory" \
  || fail "expected the extracted marker file content, got '$extracted'"

section "retention prunes older backups once the configured count is exceeded"
follow_up_ok=1
for i in 1 2 3 4; do
  if ! run_backup 3 mysql selftest >"/tmp/out-more-$i.log" 2>&1; then
    follow_up_ok=0
    cat "/tmp/out-more-$i.log"
  fi
done
[ "$follow_up_ok" = "1" ] && pass "4 follow-up runs all exit 0" \
  || fail "a follow-up run should exit 0"

final_count="$(backups 'ls -1 /backups | wc -l')"
[ "$final_count" = "3" ] \
  && pass "5 runs with retention 3 leaves exactly 3 backup sets" \
  || fail "expected 3 backup sets after pruning, got $final_count"

if backups "test -d /backups/$dir1"; then
  fail "the first, oldest backup set should have been pruned"
else
  pass "the first, oldest backup set was pruned"
fi

section "a stale .partial left by a crashed run is excluded from retention"
mapfile -t before_stale < <(backups 'ls -1 /backups | sort')
middle_before="${before_stale[1]}"

# Named to sort lexically after every real timestamped backup, so it stands
# in for a run that started after all of them and then died (OOM, a SIGKILL
# past the grace period, a host crash) before reaching backup.sh's own
# rename-on-completion. Populated the same shape as a real in-progress dir
# so a defective retention has every chance to mistake it for one.
partial_name="99999999T999999999999999Z.partial"
backups "mkdir -p /backups/$partial_name/worlds && echo mid-write > /backups/$partial_name/mysql.sql"

if run_backup 3 mysql selftest >/tmp/out-stale-partial.log 2>&1; then
  pass "a run alongside a stale .partial directory still exits 0"
else
  fail "a run alongside a stale .partial directory should exit 0"; cat /tmp/out-stale-partial.log
fi

if backups "test -d /backups/$partial_name"; then
  pass "the stale .partial directory is untouched by retention"
else
  fail "the stale .partial directory should survive retention, since it was never a real backup to prune"
fi

after_real_count="$(backups "ls -1 /backups | grep -cv '\.partial$'")"
[ "$after_real_count" = "3" ] \
  && pass "retention still holds exactly 3 real backup sets, unaffected by the stale .partial" \
  || fail "expected 3 real backup sets after retention, got $after_real_count (the stale .partial got counted as one)"

if backups "test -d /backups/$middle_before"; then
  pass "the good backup retention 3 should keep was not evicted to make room for the stale .partial"
else
  fail "a good backup ($middle_before) was pruned to make room for junk, the exact defect riftal-infra#141 fixed"
fi

section "a .partial older than PARTIAL_MAX_AGE_MINUTES is swept and logged, a fresh one survives"
# Named and populated the same as the stale partial above, but this section
# exercises the sweep itself rather than retention's deliberate blindness to
# it, so it needs its own directory: the one above stays fresh throughout
# this script and must not be swept by it either (riftal-infra#151).
stale_partial_name="77777777T777777777777777Z.partial"
fresh_partial_name="66666666T666666666666666Z.partial"
backups "mkdir -p /backups/$stale_partial_name/worlds && \
  echo mid-write > /backups/$stale_partial_name/mysql.sql && \
  touch -d '-2 hours' /backups/$stale_partial_name"
backups "mkdir -p /backups/$fresh_partial_name/worlds && \
  echo mid-write > /backups/$fresh_partial_name/mysql.sql"

if run_backup 3 mysql selftest 60 >/tmp/out-partial-sweep.log 2>&1; then
  pass "a run alongside an old and a fresh .partial still exits 0"
else
  fail "a run alongside an old and a fresh .partial should exit 0"; cat /tmp/out-partial-sweep.log
fi

if backups "test -d /backups/$stale_partial_name"; then
  fail "the .partial older than PARTIAL_MAX_AGE_MINUTES should have been swept, not left behind"
else
  pass "the .partial older than PARTIAL_MAX_AGE_MINUTES was swept"
fi

if grep -q "$stale_partial_name" /tmp/out-partial-sweep.log; then
  pass "the sweep names the removed .partial directory in the log"
else
  fail "expected the log to name the swept .partial directory"; cat /tmp/out-partial-sweep.log
fi

if backups "test -d /backups/$fresh_partial_name"; then
  pass "a fresh .partial, still within the age threshold, survives the sweep"
else
  fail "a fresh .partial must never be destroyed, it could be a run genuinely still in progress"
fi

section "a lock older than LOCK_MAX_AGE_MINUTES is swept and logged, a fresh one still blocks a run"
# Backdating the lock stands in for a run that died before its own EXIT trap
# ever ran (OOM, a SIGKILL past the grace period, a host crash) -- the one
# case mkdir's lock cannot self-release the way flock would (riftal-infra#171).
backups "mkdir /backups/.lock && touch -d '-2 hours' /backups/.lock"

if run_backup 3 mysql selftest 360 60 >/tmp/out-lock-stale.log 2>&1; then
  pass "a run behind a lock older than LOCK_MAX_AGE_MINUTES clears it and still exits 0"
else
  fail "a run behind a stale lock should clear it and exit 0"; cat /tmp/out-lock-stale.log
fi

if grep -qi 'presumed abandoned' /tmp/out-lock-stale.log; then
  pass "the stale lock sweep is logged, not silent"
else
  fail "expected the log to name the stale lock as swept"; cat /tmp/out-lock-stale.log
fi

backups 'mkdir /backups/.lock'

if run_backup 3 mysql selftest 360 60 >/tmp/out-lock-fresh.log 2>&1; then
  fail "a run behind a lock within LOCK_MAX_AGE_MINUTES should still fail fast"
else
  pass "a run behind a fresh lock within LOCK_MAX_AGE_MINUTES still fails fast, unswept"
fi

if grep -qi 'presumed abandoned' /tmp/out-lock-fresh.log; then
  fail "a fresh lock, still within the age threshold, must never be swept"
else
  pass "a fresh lock is left untouched rather than swept"
fi

backups 'rmdir /backups/.lock'

section "a lock swept while its true owner is still alive is not undone by that owner's own stale cleanup"
# QA's exact scenario on #171/#173: run A acquires the lock and is still
# genuinely alive, not crashed, when its lock crosses LOCK_MAX_AGE_MINUTES.
# Run B sees it as stale, sweeps it, and reacquires it with its own token.
# Only afterward does A reach its own EXIT trap, where its cleanup must
# recognize the lock now belongs to B, refuse to remove it, and log that it
# no longer owns the lock, rather than deleting B's lock and letting a third
# run start concurrently with B undetected. __test_acquire_lock and
# __test_release_lock drive backup.sh's real acquire_lock/release_lock
# directly so this is exercised without waiting out two real backups.
owner_a="$(run_backup 3 mysql selftest 360 60 __test_acquire_lock)"
backups "touch -d '-2 hours' /backups/.lock"
owner_b="$(run_backup 3 mysql selftest 360 60 __test_acquire_lock)"

if [ -n "$owner_a" ] && [ -n "$owner_b" ] && [ "$owner_a" != "$owner_b" ]; then
  pass "A's and B's lock acquisitions are stamped with distinct, non-empty ownership tokens"
else
  fail "expected two distinct ownership tokens, got A='$owner_a' B='$owner_b'"
fi

run_backup 3 mysql selftest 360 60 __test_release_lock "$owner_a" \
  >/tmp/out-stale-cleanup.log 2>&1

if backups 'test -d /backups/.lock'; then
  pass "B's reacquired lock survives A's own stale cleanup running with A's original token"
else
  fail "A's cleanup deleted B's lock using a token that no longer matched, the exact use-after-free QA found on #173"
fi

if grep -qi "no longer this run" /tmp/out-stale-cleanup.log; then
  pass "A's stale cleanup logs that it no longer owns the lock instead of silently deleting it"
else
  fail "expected A's cleanup to log that it no longer owns the lock"; cat /tmp/out-stale-cleanup.log
fi

backups 'rm -rf /backups/.lock'

section "two sweepers racing to steal the same abandoned lock: exactly one wins"
# riftal-infra#175: unlike the section above, neither run here is ever the
# live owner. Both independently find the same already-abandoned lock stale
# and both attempt to steal it at once. STEAL_RACE_TEST_STALL_SECONDS widens
# backup.sh's own steal-path window (a handful of syscalls in a real run, not
# landable on demand) so both runs are reliably inside it together, which is
# what makes this reproduce rather than pass by accident regardless of the
# fix: an unwidened race left both exit-0 or both exit-1 to luck on this same
# host, observed while first writing this test.
backups "mkdir /backups/.lock && echo old-owner > /backups/.lock/owner && touch -d '-2 hours' /backups/.lock"

# Captured separately from stderr, unlike most `run_backup` calls above:
# command substitution's `$(...)` would only take stdout anyway, but this
# runs both racers backgrounded rather than substituted, so it needs its own
# split to read back just the echoed owner token below.
STEAL_RACE_TEST_STALL_SECONDS=2 run_backup 3 mysql selftest 360 60 __test_acquire_lock \
  >/tmp/out-steal-race-a.log 2>/tmp/err-steal-race-a.log &
steal_race_pid_a=$!
STEAL_RACE_TEST_STALL_SECONDS=2 run_backup 3 mysql selftest 360 60 __test_acquire_lock \
  >/tmp/out-steal-race-b.log 2>/tmp/err-steal-race-b.log &
steal_race_pid_b=$!

steal_race_status_a=0; wait "$steal_race_pid_a" || steal_race_status_a=$?
steal_race_status_b=0; wait "$steal_race_pid_b" || steal_race_status_b=$?

steal_race_wins=0
[ "$steal_race_status_a" -eq 0 ] && steal_race_wins=$((steal_race_wins + 1))
[ "$steal_race_status_b" -eq 0 ] && steal_race_wins=$((steal_race_wins + 1))
if [ "$steal_race_wins" -eq 1 ]; then
  pass "exactly one of two simultaneous steal attempts against the same abandoned lock wins"
else
  fail "expected exactly one winner, got $steal_race_wins (both winning is riftal-infra#175's exact race, both losing strands the lock)"
  cat /tmp/out-steal-race-a.log /tmp/err-steal-race-a.log /tmp/out-steal-race-b.log /tmp/err-steal-race-b.log
fi

steal_race_winner_owner=""
[ "$steal_race_status_a" -eq 0 ] && steal_race_winner_owner="$(cat /tmp/out-steal-race-a.log)"
[ "$steal_race_status_b" -eq 0 ] && steal_race_winner_owner="$(cat /tmp/out-steal-race-b.log)"
steal_race_stored_owner="$(backups 'cat /backups/.lock/owner' 2>/dev/null || true)"
if [ -n "$steal_race_winner_owner" ] && [ "$steal_race_stored_owner" = "$steal_race_winner_owner" ]; then
  pass "the lock on disk is stamped with the winner's own token, not the loser's"
else
  fail "expected the stored owner to match the winner's token, got winner='$steal_race_winner_owner' stored='$steal_race_stored_owner'"
fi

steal_race_leftover="$(backups "find /backups -mindepth 1 -maxdepth 1 -name '.lock.discard.*'")"
if [ -z "$steal_race_leftover" ]; then
  pass "the loser's discarded copy of the old lock is cleaned up, not left behind"
else
  fail "expected no leftover .lock.discard.* directory, found: $steal_race_leftover"
fi

backups 'rm -rf /backups/.lock'

section "a run against a BACKUP_ROOT another run already holds the lock on fails fast"
# Stands in for a manual out-of-band run overlapping the scheduled loop
# (riftal-infra#166): holds backup.sh's own lock directory directly, without
# running backup.sh itself, so the contended run below has something real to
# fail against.
backups 'mkdir /backups/.lock'

if run_backup 3 mysql selftest >/tmp/out-lock-contended.log 2>&1; then
  fail "a run against an already-locked BACKUP_ROOT should exit nonzero"
else
  pass "a run against an already-locked BACKUP_ROOT exits nonzero"
fi

if grep -qi 'lock' /tmp/out-lock-contended.log; then
  pass "the lock contention failure is logged, not silent"
else
  fail "expected a logged lock-contention message"; cat /tmp/out-lock-contended.log
fi

backups 'rmdir /backups/.lock'

if run_backup 3 mysql selftest >/tmp/out-lock-released.log 2>&1; then
  pass "a run succeeds once the earlier run's lock is released"
else
  fail "a run should succeed once the lock is released"; cat /tmp/out-lock-released.log
fi

section "retention never treats its own held lock directory as a backup set to prune"
# A run's own lock is created at the start and released only by the EXIT
# trap at the very end, so it is present throughout that same run's own
# retention step (riftal-infra#166). Checking "does .lock exist after the
# run" cannot tell a fixed retention from a broken one: the EXIT trap's
# rmdir removes it either way once the script exits, whether or not
# retention's prune loop already got there first. What distinguishes them
# is whether that loop ever names the lock directory as something to
# prune, which its own log records regardless of timing, so BACKUP_RETENTION
# is set here to the current real backup count, guaranteeing this run's
# retention step has something to prune and so actually exercises the
# excluded-name list.
retention_lock_count="$(backups "ls -1 /backups | grep -cv '\.partial$'")"
if run_backup "$retention_lock_count" mysql selftest >/tmp/out-lock-retention.log 2>&1; then
  pass "a run whose own retention step has something to prune still exits 0"
else
  fail "a run whose own retention step has something to prune should exit 0"; cat /tmp/out-lock-retention.log
fi

if grep -q 'pruning .*\.lock' /tmp/out-lock-retention.log; then
  fail "retention named the lock directory as a prune candidate, riftal-infra#166's exact regression"
else
  pass "retention never names the lock directory as a prune candidate"
fi

section "an unreachable database fails loudly instead of producing nothing"
if run_backup 10 no-such-mysql-host selftest >/tmp/out-unreachable.log 2>&1; then
  fail "a run against an unreachable database should exit nonzero"
else
  pass "a run against an unreachable database exits nonzero"
fi
if grep -qi 'backup' /tmp/out-unreachable.log; then
  pass "the failure is logged, not silent"
else
  fail "expected a logged failure message"; cat /tmp/out-unreachable.log
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
printf 'all %s assertions passed: coordinated restorable backup, retention pruning, stale .partial sweep, concurrent-run lock, stale-lock sweep, lock ownership token, steal-vs-steal mutual exclusion, loud failure.\n' "$PASSES"
