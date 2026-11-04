#!/usr/bin/env bash
# Self-test for backup.sh, against a real, throwaway mysql:8 container and
# real, throwaway world volumes. backup.sh runs in an image built here from
# ../images/backup, since mysql:8 carries no flock. Calls `docker` directly, as
# ../migrations/selftest.sh does, so it runs on the self-hosted CI runner and,
# on Nasir's Windows machine, under the WSL fallback engine:
#   wsl -d Ubuntu-26.04 -u runner --exec bash /mnt/c/.../deploy/selftest.sh
# ../deploy/README.md shows a manual backup run under wslc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX="$$-$(date +%s)"
NETWORK="riftal-backup-selftest-net-$SUFFIX"
MYSQL_CONTAINER="riftal-backup-selftest-mysql-$SUFFIX"
BACKUPS_VOL="riftal-backup-selftest-backups-$SUFFIX"
WORLD_A_VOL="riftal-backup-selftest-world-a-$SUFFIX"
WORLD_B_VOL="riftal-backup-selftest-world-b-$SUFFIX"
CAPTURE_VOL="riftal-backup-selftest-capture-$SUFFIX"
RUN_NAME_KILLED="riftal-backup-selftest-killed-$SUFFIX"
RUN_NAME_SHIM="riftal-backup-selftest-shim-$SUFFIX"
HOLDER="riftal-backup-selftest-holder-$SUFFIX"
BACKUP_IMG="riftal-backup-selftest:$SUFFIX"

# Per run, so two runs sharing a host, as the self-hosted CI runners do,
# never read each other's logs.
LOGS="$(mktemp -d)"

cleanup() {
  docker rm -f -v "$MYSQL_CONTAINER" "$HOLDER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker volume rm "$BACKUPS_VOL" "$WORLD_A_VOL" "$WORLD_B_VOL" "$CAPTURE_VOL" >/dev/null 2>&1 || true
  docker image rm "$BACKUP_IMG" >/dev/null 2>&1 || true
  rm -rf "$LOGS"
}
trap cleanup EXIT

docker build -q -t "$BACKUP_IMG" "$SCRIPT_DIR/../images/backup" >/dev/null
docker network create "$NETWORK" >/dev/null
# Created before any `run -v` names them, so CI's label shim stamps them for
# the job's sweep, which is all that removes them when a cancel skips the trap.
docker volume create "$BACKUPS_VOL" >/dev/null
docker volume create "$WORLD_A_VOL" >/dev/null
docker volume create "$WORLD_B_VOL" >/dev/null
docker volume create "$CAPTURE_VOL" >/dev/null

docker run -d --rm -m 1g --cpus 1 --name "$MYSQL_CONTAINER" --network "$NETWORK" --network-alias mysql \
  -v "$WORLD_A_VOL:/instance-a" -v "$CAPTURE_VOL:/capture:ro" \
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
docker exec -i "$MYSQL_CONTAINER" mysql -uroot -pselftest riftal_selftest <"$SCRIPT_DIR/fence-fixture.sql"
docker exec -i "$MYSQL_CONTAINER" mysql -uroot -pselftest riftal_selftest <"$SCRIPT_DIR/fence-listing-fixture.sql"

docker run --rm -m 1g --cpus 1 -v "$WORLD_A_VOL:/world" mysql:8 bash -c \
  'echo world-a-marker > /world/marker.txt' >/dev/null
docker run --rm -m 1g --cpus 1 -v "$WORLD_B_VOL:/world" mysql:8 bash -c \
  'echo world-b-marker > /world/marker.txt' >/dev/null

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=78
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

# Any argument past the first 5 is forwarded to backup.sh itself, so a
# caller can drive its __test_acquire_lock / __test_release_lock entry
# points (riftal-infra#173) instead of always running the full script.
run_backup() {
  local retention="$1" host="$2" password="$3" partial_max_age="${4:-360}" lock_max_age="${5:-90}"
  if [ "$#" -gt 5 ]; then shift 5; else shift "$#"; fi
  timeout 60 docker run --rm -m 1g --cpus 1 --network "$NETWORK" ${RUN_NAME:+--name "$RUN_NAME"} \
    ${TAR_SHIM:+-v "$TAR_SHIM:/shim/tar:ro" -e PATH=/shim:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin} \
    -e SHIM_VOL="${SHIM_VOL:-}" -e SHIM_EXIT="${SHIM_EXIT:-0}" -e SHIM_CALLS="${SHIM_CALLS:-first}" \
    -v "${BACKUP_SCRIPT:-$SCRIPT_DIR/backup.sh}:/deploy/backup.sh:ro" \
    -v "$BACKUPS_VOL:/backups" -v "$CAPTURE_VOL:/capture" \
    -v "$WORLD_A_VOL:/worlds/world-a:ro" -v "$WORLD_B_VOL:/worlds/world-b:ro" \
    -e MYSQL_HOST="$host" -e MYSQL_USER=root -e MYSQL_PASSWORD="$password" \
    -e MYSQL_DATABASE=riftal_selftest -e BACKUP_RETENTION="$retention" \
    -e PARTIAL_MAX_AGE_MINUTES="$partial_max_age" -e LOCK_MAX_AGE_MINUTES="$lock_max_age" \
    -e STEAL_RACE_TEST_STALL_SECONDS="${STEAL_RACE_TEST_STALL_SECONDS:-0}" \
    -e DISCARD_RACE_TEST_STALL_SECONDS="${DISCARD_RACE_TEST_STALL_SECONDS:-0}" \
    -e CLAIM_RACE_TEST_STALL_SECONDS="${CLAIM_RACE_TEST_STALL_SECONDS:-0}" \
    -e CAPTURE_FENCE_MAX_SECONDS="${CAPTURE_FENCE_MAX_SECONDS:-1800}" \
    -e CAPTURE_HOLD_MAX_SECONDS="${CAPTURE_HOLD_MAX_SECONDS:-900}" \
    -e CAPTURE_ACK_TIMEOUT_SECONDS="${CAPTURE_ACK_TIMEOUT_SECONDS:-60}" \
    -e CAPTURE_TEST_REQUEST_ID="${CAPTURE_TEST_REQUEST_ID:-}" \
    -e FENCE_TEST_STALL_SECONDS="${FENCE_TEST_STALL_SECONDS:-0}" \
    -e CAPTURE_TEST_STALL_SECONDS="${CAPTURE_TEST_STALL_SECONDS:-0}" \
    "$BACKUP_IMG" bash /deploy/backup.sh "$@"
}

backups() {
  docker run --rm -m 1g --cpus 1 -v "$BACKUPS_VOL:/backups" mysql:8 bash -c "$1"
}

section "a run captures a restorable, coordinated dump and world snapshots"
if run_backup 10 mysql selftest >"$LOGS"/out-run1.log 2>&1; then
  pass "first run exits 0"
else
  fail "first run should exit 0"; cat "$LOGS"/out-run1.log
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

fence_row() {
  docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest -N -B riftal_selftest -e \
    "SELECT COALESCE(request_id, 'lowered') FROM capture_fence WHERE id = 1"
}

section "the capture fence is raised for the run, lowered after it, and named in the manifest"
backups "grep -qx 'capture_fence: $dir1' /backups/$dir1/manifest.txt" \
  && pass "the manifest names the run's capture fence request id" \
  || fail "expected 'capture_fence: $dir1' in the manifest"
[ "$(fence_row)" = "lowered" ] \
  && pass "the fence is lowered once the run has exited" \
  || fail "expected the fence lowered after a run, got '$(fence_row)'"

docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest riftal_selftest -e \
  "UPDATE capture_fence SET request_id = 'other-run', raised_until = UTC_TIMESTAMP(3) + INTERVAL 600 SECOND WHERE id = 1"
if run_backup 10 mysql selftest >"$LOGS"/out-fence-busy.log 2>&1; then
  fail "a run against another run's live fence should fail"; cat "$LOGS"/out-fence-busy.log
else
  pass "a run against another run's live fence exits nonzero"
fi
grep -q "another run's lease is live" "$LOGS"/out-fence-busy.log \
  && ! grep -q "dumping database" "$LOGS"/out-fence-busy.log \
  && pass "the busy refusal is logged with its reason, before any dump starts" \
  || { fail "expected the busy refusal in the log and no dump started"; cat "$LOGS"/out-fence-busy.log; }
[ "$(backups 'ls -1 /backups | wc -l')" = "1" ] && [ "$(fence_row)" = "other-run" ] \
  && pass "a busy refusal writes no set and leaves the other run's fence raised" \
  || fail "expected one set and the other run's fence untouched, got fence '$(fence_row)'"
docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest riftal_selftest -e \
  "UPDATE capture_fence SET request_id = NULL, raised_until = NULL WHERE id = 1"

for bad in 900 3601; do
  if CAPTURE_FENCE_MAX_SECONDS="$bad" run_backup 10 mysql selftest >"$LOGS/out-fence-max-$bad.log" 2>&1; then
    fail "CAPTURE_FENCE_MAX_SECONDS=$bad should refuse to start"
  elif grep -q "CAPTURE_FENCE_MAX_SECONDS '$bad' must be above" "$LOGS/out-fence-max-$bad.log"; then
    pass "CAPTURE_FENCE_MAX_SECONDS=$bad is refused at start"
  else
    fail "expected the start refusal for $bad"; cat "$LOGS/out-fence-max-$bad.log"
  fi
done

section "retention prunes older backups once the configured count is exceeded"
follow_up_ok=1
for i in 1 2 3 4; do
  if ! run_backup 3 mysql selftest >"$LOGS/out-more-$i.log" 2>&1; then
    follow_up_ok=0
    cat "$LOGS/out-more-$i.log"
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

if run_backup 3 mysql selftest >"$LOGS"/out-stale-partial.log 2>&1; then
  pass "a run alongside a stale .partial directory still exits 0"
else
  fail "a run alongside a stale .partial directory should exit 0"; cat "$LOGS"/out-stale-partial.log
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

if run_backup 3 mysql selftest 60 >"$LOGS"/out-partial-sweep.log 2>&1; then
  pass "a run alongside an old and a fresh .partial still exits 0"
else
  fail "a run alongside an old and a fresh .partial should exit 0"; cat "$LOGS"/out-partial-sweep.log
fi

if backups "test -d /backups/$stale_partial_name"; then
  fail "the .partial older than PARTIAL_MAX_AGE_MINUTES should have been swept, not left behind"
else
  pass "the .partial older than PARTIAL_MAX_AGE_MINUTES was swept"
fi

if grep -q "$stale_partial_name" "$LOGS"/out-partial-sweep.log; then
  pass "the sweep names the removed .partial directory in the log"
else
  fail "expected the log to name the swept .partial directory"; cat "$LOGS"/out-partial-sweep.log
fi

if backups "test -d /backups/$fresh_partial_name"; then
  pass "a fresh .partial, still within the age threshold, survives the sweep"
else
  fail "a fresh .partial must never be destroyed, it could be a run genuinely still in progress"
fi

section "a lock older than LOCK_MAX_AGE_MINUTES is swept and logged, a fresh one still blocks a run"
# Backdating the lock stands in for a run that died before its own EXIT trap
# ever ran (OOM, a SIGKILL past the grace period, a host crash) -- the one
# case a directory lock cannot self-release the way flock would
# (riftal-infra#171).
backups "mkdir /backups/.lock && touch -d '-2 hours' /backups/.lock"

if run_backup 3 mysql selftest 360 60 >"$LOGS"/out-lock-stale.log 2>&1; then
  pass "a run behind a lock older than LOCK_MAX_AGE_MINUTES clears it and still exits 0"
else
  fail "a run behind a stale lock should clear it and exit 0"; cat "$LOGS"/out-lock-stale.log
fi

if grep -qi 'presumed abandoned' "$LOGS"/out-lock-stale.log; then
  pass "the stale lock sweep is logged, not silent"
else
  fail "expected the log to name the stale lock as swept"; cat "$LOGS"/out-lock-stale.log
fi

backups 'mkdir /backups/.lock'

if run_backup 3 mysql selftest 360 60 >"$LOGS"/out-lock-fresh.log 2>&1; then
  fail "a run behind a lock within LOCK_MAX_AGE_MINUTES should still fail fast"
else
  pass "a run behind a fresh lock within LOCK_MAX_AGE_MINUTES still fails fast, unswept"
fi

if grep -qi 'presumed abandoned' "$LOGS"/out-lock-fresh.log; then
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
  >"$LOGS"/out-stale-cleanup.log 2>&1

if backups 'test -d /backups/.lock'; then
  pass "B's reacquired lock survives A's own stale cleanup running with A's original token"
else
  fail "A's cleanup deleted B's lock using a token that no longer matched, the exact use-after-free QA found on #173"
fi

if grep -qi "no longer this run" "$LOGS"/out-stale-cleanup.log; then
  pass "A's stale cleanup logs that it no longer owns the lock instead of silently deleting it"
else
  fail "expected A's cleanup to log that it no longer owns the lock"; cat "$LOGS"/out-stale-cleanup.log
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
  >"$LOGS"/out-steal-race-a.log 2>"$LOGS"/err-steal-race-a.log &
steal_race_pid_a=$!
STEAL_RACE_TEST_STALL_SECONDS=2 run_backup 3 mysql selftest 360 60 __test_acquire_lock \
  >"$LOGS"/out-steal-race-b.log 2>"$LOGS"/err-steal-race-b.log &
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
  cat "$LOGS"/out-steal-race-a.log "$LOGS"/err-steal-race-a.log "$LOGS"/out-steal-race-b.log "$LOGS"/err-steal-race-b.log
fi

steal_race_winner_owner=""
[ "$steal_race_status_a" -eq 0 ] && steal_race_winner_owner="$(cat "$LOGS"/out-steal-race-a.log)"
[ "$steal_race_status_b" -eq 0 ] && steal_race_winner_owner="$(cat "$LOGS"/out-steal-race-b.log)"
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

section "no .lock is visible before it is stamped, so two racing sweepers leave exactly one winner"
# riftal-infra#491. No .lock is visible before its owner file is written, so
# exactly one of two runs racing to steal the same abandoned lock wins.
# L sets DISCARD_RACE_TEST_STALL_SECONDS because that stall is what makes a
# claim that creates .lock before stamping it go red here.
backups "mkdir /backups/.lock && echo old-owner > /backups/.lock/owner && touch -d '-2 hours' /backups/.lock"

STEAL_RACE_TEST_STALL_SECONDS=2 CLAIM_RACE_TEST_STALL_SECONDS=3 \
  run_backup 3 mysql selftest 360 60 __test_acquire_lock \
  >"$LOGS"/out-claim-race-w.log 2>"$LOGS"/err-claim-race-w.log &
claim_race_pid_w=$!
STEAL_RACE_TEST_STALL_SECONDS=3 DISCARD_RACE_TEST_STALL_SECONDS=5 \
  run_backup 3 mysql selftest 360 60 __test_acquire_lock \
  >"$LOGS"/out-claim-race-l.log 2>"$LOGS"/err-claim-race-l.log &
claim_race_pid_l=$!

claim_race_status_w=0; wait "$claim_race_pid_w" || claim_race_status_w=$?
claim_race_status_l=0; wait "$claim_race_pid_l" || claim_race_status_l=$?

claim_race_winner_owner=""
claim_race_wins=0
if [ "$claim_race_status_w" -eq 0 ]; then
  claim_race_wins=$((claim_race_wins + 1))
  claim_race_winner_owner="$(cat "$LOGS"/out-claim-race-w.log)"
fi
if [ "$claim_race_status_l" -eq 0 ]; then
  claim_race_wins=$((claim_race_wins + 1))
  claim_race_winner_owner="$(cat "$LOGS"/out-claim-race-l.log)"
fi
if [ "$claim_race_wins" -eq 1 ]; then
  pass "exactly one of two sweepers racing a claim wins"
else
  fail "expected exactly one winner, got $claim_race_wins (zero is riftal-infra#491's stranded lock)"
  cat "$LOGS"/err-claim-race-w.log "$LOGS"/err-claim-race-l.log
fi

claim_race_stored_owner="$(backups 'cat /backups/.lock/owner' 2>/dev/null || true)"
if [ -n "$claim_race_winner_owner" ] && [ "$claim_race_stored_owner" = "$claim_race_winner_owner" ]; then
  pass "the lock left on disk carries the winner's token, never an empty owner"
else
  fail "expected the stored owner to match the winner's token, got winner='$claim_race_winner_owner' stored='$claim_race_stored_owner'"
fi

claim_race_leftover="$(backups "find /backups -mindepth 1 -maxdepth 1 -name '.lock.discard.*'")"
if [ -z "$claim_race_leftover" ]; then
  pass "no .lock.discard.* directory from either run is left behind"
else
  fail "expected no leftover .lock.discard.* directory, found: $claim_race_leftover"
fi

backups 'rm -rf /backups/.lock'

section "an orphaned .lock.discard.* from a run killed mid-cleanup is swept on the next lock acquisition"
# Stands in for a run that won acquire_lock's steal-path rename
# (`mv -T "$LOCK_DIR" "$discard_dir"`) and was then killed before reaching
# its own `rm -rf "$discard_dir"` (riftal-infra#187), rather than waiting out
# that exact kill timing to reproduce it.
orphan_discard_name=".lock.discard.99999-orphaned"
backups "mkdir -p /backups/$orphan_discard_name && echo 99999-orphaned > /backups/$orphan_discard_name/owner"

if run_backup 3 mysql selftest >"$LOGS"/out-discard-sweep.log 2>&1; then
  pass "a run alongside an orphaned .lock.discard.* still exits 0"
else
  fail "a run alongside an orphaned .lock.discard.* should exit 0"; cat "$LOGS"/out-discard-sweep.log
fi

if backups "test -d /backups/$orphan_discard_name"; then
  fail "the orphaned .lock.discard.* should have been swept, not left behind"
else
  pass "the orphaned .lock.discard.* was swept"
fi

if grep -q "$orphan_discard_name" "$LOGS"/out-discard-sweep.log; then
  pass "the sweep names the removed .lock.discard.* directory in the log"
else
  fail "expected the log to name the swept .lock.discard.* directory"; cat "$LOGS"/out-discard-sweep.log
fi

section "a discard directory swept while its rename-owner is still alive converges on the same lock-contention failure"
# riftal-infra#207/#208: the section above covers an orphan nobody is still
# running; this covers the case the comment above backup.sh's
# `stale_discards` sweep specifically claims is also safe. A backdated .lock
# puts run A on the same steal path as every section above, so its own
# rename (`mv -T "$LOCK_DIR" "$discard_dir"` in acquire_lock) produces a
# discard directory while A is still alive, not crashed.
# DISCARD_RACE_TEST_STALL_SECONDS holds A there until run B, an entirely
# ordinary full run needing nothing special of its own, reaches its
# `stale_discards` sweep and removes it. A must then find its own discard
# directory gone at its staleness check (`find "$discard_dir" -maxdepth 0
# -mmin` in acquire_lock) and hand the lock back rather than proceed as if
# it still owned it.
backups "mkdir /backups/.lock && echo old-owner > /backups/.lock/owner && touch -d '-2 hours' /backups/.lock"

DISCARD_RACE_TEST_STALL_SECONDS=5 run_backup 3 mysql selftest 360 60 __test_acquire_lock \
  >"$LOGS"/out-discard-race-a.log 2>"$LOGS"/err-discard-race-a.log &
discard_race_pid_a=$!

# A's own container start, failed claim, staleness check and rename all land
# well inside this, leaving B the run of its own stall to land its sweep in.
sleep 2
discard_race_status_b=0
run_backup 3 mysql selftest >"$LOGS"/out-discard-race-b.log 2>&1 || discard_race_status_b=$?

discard_race_status_a=0
wait "$discard_race_pid_a" || discard_race_status_a=$?

if [ "$discard_race_status_b" -eq 0 ]; then
  pass "the concurrent run that sweeps the still-alive owner's discard directory completes normally"
else
  fail "the concurrent sweeping run should exit 0"; cat "$LOGS"/out-discard-race-b.log
fi

if [ "$discard_race_status_a" -ne 0 ]; then
  pass "the still-alive owner whose discard directory was swept out from under it fails rather than proceeding as if it still held the lock"
else
  fail "expected the still-alive owner to fail once its discard directory vanished, it exited 0 instead"
fi

if grep -q 'another run already holds the lock' "$LOGS"/err-discard-race-a.log; then
  pass "the still-alive owner fails with the same lock-contention message every other contention path produces"
else
  fail "expected the documented lock-contention message"; cat "$LOGS"/err-discard-race-a.log
fi

if backups "find /backups -mindepth 1 -maxdepth 1 \( -name '.lock' -o -name '.lock.discard.*' \) | grep -q ."; then
  fail "expected no leftover lock or discard directory once both runs have exited, a sign of a double lock acquisition or orphaned state"
else
  pass "no lock or discard directory is left behind once both runs have exited: exactly one run held the lock, cleanly"
fi

backups 'rm -rf /backups/.lock /backups/.lock.discard.*'

section "a run against a BACKUP_ROOT another run already holds the lock on fails fast"
# Stands in for a manual out-of-band run overlapping the scheduled loop
# (riftal-infra#166): holds backup.sh's own lock directory directly, without
# running backup.sh itself, so the contended run below has something real to
# fail against.
backups 'mkdir /backups/.lock'

if run_backup 3 mysql selftest >"$LOGS"/out-lock-contended.log 2>&1; then
  fail "a run against an already-locked BACKUP_ROOT should exit nonzero"
else
  pass "a run against an already-locked BACKUP_ROOT exits nonzero"
fi

if grep -qi 'lock' "$LOGS"/out-lock-contended.log; then
  pass "the lock contention failure is logged, not silent"
else
  fail "expected a logged lock-contention message"; cat "$LOGS"/out-lock-contended.log
fi

backups 'rmdir /backups/.lock'

if run_backup 3 mysql selftest >"$LOGS"/out-lock-released.log 2>&1; then
  pass "a run succeeds once the earlier run's lock is released"
else
  fail "a run should succeed once the lock is released"; cat "$LOGS"/out-lock-released.log
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
if run_backup "$retention_lock_count" mysql selftest >"$LOGS"/out-lock-retention.log 2>&1; then
  pass "a run whose own retention step has something to prune still exits 0"
else
  fail "a run whose own retention step has something to prune should exit 0"; cat "$LOGS"/out-lock-retention.log
fi

if grep -q 'pruning .*\.lock' "$LOGS"/out-lock-retention.log; then
  fail "retention named the lock directory as a prune candidate, riftal-infra#166's exact regression"
else
  pass "retention never names the lock directory as a prune candidate"
fi

section "an unreachable database fails loudly instead of producing nothing"
if run_backup 10 no-such-mysql-host selftest >"$LOGS"/out-unreachable.log 2>&1; then
  fail "a run against an unreachable database should exit nonzero"
else
  pass "a run against an unreachable database exits nonzero"
fi
if grep -qi 'backup' "$LOGS"/out-unreachable.log; then
  pass "the failure is logged, not silent"
else
  fail "expected a logged failure message"; cat "$LOGS"/out-unreachable.log
fi

section "the capture fence closes the copy: a held item is collected once, and each mutant of backup.sh copies it"
# ADR 027 P6. The MySQL container stands in for an instance whose world is
# world-a: a shell responder calls the fixture commit-first procedure as the
# plugin would, writes a delivery marker into players/ on a commit, then stages
# players/ and acks. A holder container keeps a shared flock on the volume's
# server.lock, as core does, so the volume reads as running and its ack decides.
# The responder calls twice: while the run stalls between its dump and its
# request, and again while the volume's second ack wait is open after a forced
# retry, which an ack the responder removes causes. A correct run holds the
# fence across both, so each call must answer capture_fenced.
INSTANCE=/instance-a
INSTANCE_ACK='
id="$1"
for _ in $(seq 150); do
  [ "$(cut -d" " -f1 /capture/request 2>/dev/null)" = "$id" ] && break
  sleep 0.2
done
[ "$(cut -d" " -f1 /capture/request 2>/dev/null)" = "$id" ] || exit 1
rm -rf "/instance-a/.capture/$id/players"
mkdir -p /instance-a/players "/instance-a/.capture/$id"
cp -a /instance-a/players "/instance-a/.capture/$id/players"
printf "%s\n%s\n" "$id" 1700000000000000 > "/instance-a/.capture/$id/ack.tmp"
mv -f "/instance-a/.capture/$id/ack.tmp" "/instance-a/.capture/$id/ack"
'

sql() { docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest -N -B "${2:-riftal_selftest}" -e "$1" 2>/dev/null; }
set_count() { backups 'ls -1 /backups | wc -l'; }

# $1 a literal, $2 a file, $3 seconds to wait for the literal in it
await_log() {
  local i
  for ((i = 0; i < $3 * 5; i++)); do
    grep -qF -- "$1" "$2" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

collect_item() {
  local outcome
  outcome="$(sql 'CALL fixture_listing_collect(1, "responder", @o); SELECT @o')"
  [ "$outcome" != collected ] \
    || docker exec "$MYSQL_CONTAINER" bash -c "mkdir -p $INSTANCE/players && echo item > $INSTANCE/players/marker.dat"
  echo "$outcome"
}

# $1 the run's log, $2 its request id, $3 seconds after the dump starts before the first call
fence_responder() {
  await_log "dumping database" "$1" 30
  sleep "$3"
  collect_item
  docker exec "$MYSQL_CONTAINER" bash -c "$INSTANCE_ACK" _ "$2"
  await_log "volume world-a is held for request" "$1" 30
  docker exec "$MYSQL_CONTAINER" rm -f "$INSTANCE/.capture/$2/ack"
  await_log "lost its ack" "$1" 30
  # A run that lowers the fence here does so within a moment of this line.
  sleep 2
  collect_item
  docker exec "$MYSQL_CONTAINER" bash -c "$INSTANCE_ACK" _ "$2"
}

fence_reset() {
  sql 'UPDATE capture_fence SET request_id = NULL, raised_until = NULL WHERE id = 1;
       UPDATE fixture_listing SET collected_by = NULL'
  docker exec "$MYSQL_CONTAINER" rm -rf "$INSTANCE/players" "$INSTANCE/.capture"
}

# Runs backup.sh with the responder. $1 case name (letters only), $2 the script
# to run, $3 the fence lease, $4 FENCE_TEST_STALL_SECONDS, $5 seconds after the
# dump starts before the responder first calls. Sets fence_rc, fence_new (sets
# written), fence_item (the restored fixture row) and fence_marker (1 when the
# restored world holds the delivery marker).
fence_run() {
  local name="$1" id="fence-$1" db="riftal_selftest_r_$1" before set_name responder
  fence_reset
  before="$(set_count)"
  fence_responder "$LOGS/run-$name.log" "$id" "$5" >"$LOGS/responder-$name.log" 2>&1 &
  responder=$!
  fence_rc=0
  BACKUP_SCRIPT="$2" CAPTURE_TEST_REQUEST_ID="$id" CAPTURE_FENCE_MAX_SECONDS="$3" CAPTURE_HOLD_MAX_SECONDS=3 \
    FENCE_TEST_STALL_SECONDS="$4" CAPTURE_TEST_STALL_SECONDS=5 \
    run_backup 50 mysql selftest >"$LOGS/run-$name.log" 2>&1 || fence_rc=$?
  wait "$responder" || true
  fence_new=$(( $(set_count) - before ))
  fence_item="" fence_marker=""
  set_name="$(sed -n 's|.*complete at /backups/||p' "$LOGS/run-$name.log")"
  if [ -n "$set_name" ]; then
    sql "CREATE DATABASE $db"
    backups "cat /backups/$set_name/mysql.sql" | docker exec -i "$MYSQL_CONTAINER" mysql -uroot -pselftest "$db" 2>/dev/null
    fence_item="$(sql 'SELECT COALESCE(collected_by, "none") FROM fixture_listing WHERE id = 1' "$db")"
    fence_marker="$(backups "tar -tzf /backups/$set_name/worlds/world-a.tar.gz | grep -c '^players/marker.dat\$' || true")"
  fi
}

# $1 a name, $2 how many lines of backup.sh the sed arguments after it change.
# Leaves the mutant's path in $mutant. The changed-line count catches a pattern
# that matches more lines than intended and a backup.sh whose shape has drifted
# from what the patterns expect.
mutate() {
  local name="$1" lines="$2"
  shift 2
  mutant="$LOGS/backup-$name.sh"
  sed "$@" "$SCRIPT_DIR/backup.sh" >"$mutant"
  [ "$(diff "$SCRIPT_DIR/backup.sh" "$mutant" | grep -c '^<' || true)" = "$lines" ] \
    || fail "the $name mutant did not change exactly $lines line(s) of backup.sh"
}

# True when a set was written that holds the row uncollected and the delivery both.
two_copies() {
  [ "$fence_rc" = 0 ] && [ "$fence_new" = 1 ] && [ "$fence_item" = none ] && [ "$fence_marker" = 1 ]
}

holding=0
# $1 held, free or absent: what the volume's server.lock is. The held lock is
# taken in a container of its own, as core takes it, and a stopped container
# releases it.
set_lock() {
  if [ "$1" = held ] && [ "$holding" = 1 ]; then
    return 0
  fi
  if [ "$holding" = 1 ]; then
    docker stop -t 1 "$HOLDER" >/dev/null
    holding=0
  fi
  docker exec "$MYSQL_CONTAINER" rm -f "$INSTANCE/server.lock"
  case "$1" in
    free) docker exec "$MYSQL_CONTAINER" touch "$INSTANCE/server.lock" ;;
    held)
      docker run -d --rm --init -m 1g --cpus 1 --name "$HOLDER" -v "$WORLD_A_VOL:/instance-a" \
        "$BACKUP_IMG" flock -s /instance-a/server.lock sleep 3600 >/dev/null
      holding=1
      for _ in $(seq 100); do
        docker exec "$HOLDER" flock -xn -E 99 /instance-a/server.lock true || [ $? != 99 ] || break
        sleep 0.2
      done
      ;;
  esac
}

set_lock held

fence_run clean "$SCRIPT_DIR/backup.sh" 120 6 2
if [ "$fence_rc" = 0 ] && [ "$fence_new" = 1 ] && [ "$fence_item" = none ] && [ "$fence_marker" = 0 ]; then
  pass "restoring the set shows the item once: the fixture row uncollected and no delivery marker"
else
  fail "expected one set, an uncollected row and no marker, got rc=$fence_rc sets=$fence_new row='$fence_item' marker='$fence_marker'"
  cat "$LOGS/run-clean.log" "$LOGS/responder-clean.log"
fi
[ "$(grep -c '^capture_fenced$' "$LOGS/responder-clean.log")" = 2 ] \
  && pass "the commit-first procedure answered capture_fenced during the stall and during the retried ack wait" \
  || { fail "expected capture_fenced twice from the responder"; cat "$LOGS/responder-clean.log"; }
[ "$(fence_row)" = lowered ] \
  && pass "the fence is lowered once the commit-first clean run has exited" \
  || fail "expected the fence lowered, got '$(fence_row)'"

# Each mutant also blinds the end check, which would otherwise fail the run
# before it wrote a set to restore. The control under test is the one removed.
mutate noraise 2 -e '/^raise_fence$/d' -e 's/^check_fence_lease$/:/'
fence_run noraise "$mutant" 120 6 2
two_copies && pass "mutant: with the raise removed the restored set holds the row uncollected and the marker, two copies" \
  || { fail "the no-raise mutant should leave two copies, got rc=$fence_rc sets=$fence_new row='$fence_item' marker='$fence_marker'"; cat "$LOGS/run-noraise.log"; }

mutate earlylower 2 -e 's/^    await_volume "\$name"$/    lower_fence; await_volume "$name"/' -e 's/^check_fence_lease$/:/'
fence_run earlylower "$mutant" 120 6 2
two_copies && pass "mutant: with the fence lowered before a retried volume's second ack the restored set holds two copies" \
  || { fail "the early-lower mutant should leave two copies, got rc=$fence_rc sets=$fence_new row='$fence_item' marker='$fence_marker'"; cat "$LOGS/run-earlylower.log"; }

section "run failures: a lapsed lease, a missing table, an unacked instance and a failed dump leave no set, and the fence comes down"
# ADR 027 P7. The busy raise and the two start refusals are asserted above.
# A 6s lease with a stall of 12s and a first call at 8s puts the call after the
# lease has lapsed, while the lease stays above the 3s hold.
fence_run lapsed "$SCRIPT_DIR/backup.sh" 6 12 8
if [ "$fence_rc" != 0 ] && [ "$fence_new" = 0 ] && grep -q "capture fence lapsed before the last volume was verified" "$LOGS/run-lapsed.log"; then
  pass "a run whose lease lapsed before the last verification fails with its reason and writes no set"
else
  fail "expected a failed run, no set and the lapsed reason, got rc=$fence_rc sets=$fence_new"; cat "$LOGS/run-lapsed.log"
fi
[ "$(fence_row)" = lowered ] \
  && pass "the trap lowers the fence of a run that failed its end check" \
  || fail "expected the fence lowered after the lapsed run, got '$(fence_row)'"

mutate nocheck 1 -e 's/^check_fence_lease$/:/'
fence_run nocheck "$mutant" 6 12 8
two_copies && pass "mutant: with the end check removed and the lease lapsed, a set is produced holding two copies" \
  || { fail "the no-check mutant should leave two copies, got rc=$fence_rc sets=$fence_new row='$fence_item' marker='$fence_marker'"; cat "$LOGS/run-nocheck.log"; }

fence_reset
before="$(set_count)"
sql 'RENAME TABLE capture_fence TO capture_fence_off' >/dev/null
missing_rc=0
run_backup 50 mysql selftest >"$LOGS/run-missing.log" 2>&1 || missing_rc=$?
sql 'RENAME TABLE capture_fence_off TO capture_fence' >/dev/null
if [ "$missing_rc" != 0 ] && [ "$(set_count)" = "$before" ] && grep -q "could not raise the capture fence" "$LOGS/run-missing.log" \
  && ! grep -q "dumping database" "$LOGS/run-missing.log"; then
  pass "a run without the fence table fails with its reason before any dump and writes no set"
else
  fail "expected a failed run, no set and no dump"; cat "$LOGS/run-missing.log"
fi

fence_reset
before="$(set_count)"
ack_rc=0
CAPTURE_ACK_TIMEOUT_SECONDS=3 CAPTURE_HOLD_MAX_SECONDS=3 run_backup 50 mysql selftest >"$LOGS/run-unacked.log" 2>&1 || ack_rc=$?
if [ "$ack_rc" != 0 ] && [ "$(set_count)" = "$before" ] && grep -q "has not acked" "$LOGS/run-unacked.log" && [ "$(fence_row)" = lowered ]; then
  pass "a run whose running instance never acks fails with its reason, writes no set and lowers the fence"
else
  fail "expected a failed run, no set and a lowered fence, got '$(fence_row)'"; cat "$LOGS/run-unacked.log"
fi

fence_reset
before="$(set_count)"
sql 'CREATE TABLE dump_gone (a INT); CREATE VIEW dump_broken AS SELECT a FROM dump_gone; DROP TABLE dump_gone' >/dev/null
dump_rc=0
run_backup 50 mysql selftest >"$LOGS/run-dump.log" 2>&1 || dump_rc=$?
sql 'DROP VIEW dump_broken' >/dev/null
if [ "$dump_rc" != 0 ] && [ "$(set_count)" = "$before" ] && grep -q "dumping database" "$LOGS/run-dump.log" && [ "$(fence_row)" = lowered ]; then
  pass "a run whose dump fails writes no set and lowers the fence"
else
  fail "expected a failed dump, no set and a lowered fence, got '$(fence_row)'"; cat "$LOGS/run-dump.log"
fi

# The run is killed with SIGKILL during its stall, so its trap never runs. The
# fence it raised is the only thing left in the database, and it lapses at its
# 8s lease.
fence_reset
RUN_NAME="$RUN_NAME_KILLED" CAPTURE_FENCE_MAX_SECONDS=8 CAPTURE_HOLD_MAX_SECONDS=3 FENCE_TEST_STALL_SECONDS=60 \
  run_backup 50 mysql selftest >"$LOGS/run-killed.log" 2>&1 &
killed_pid=$!
await_log "dumping database" "$LOGS/run-killed.log" 30
sleep 2
docker kill "$RUN_NAME_KILLED" >/dev/null
wait "$killed_pid" || true
[ "$(fence_row)" != lowered ] \
  && pass "a run killed with SIGKILL leaves its fence raised, as its trap never ran" \
  || fail "expected the killed run's fence still raised"
sleep 8
[ "$(sql 'CALL capture_fence_raise("after-kill", 5, @o); SELECT @o')" = raised ] \
  && pass "the killed run's fence lapses at its lease, and a later run raises it" \
  || fail "expected a raise to succeed once the killed run's lease had lapsed"

section "the lock test chooses held, stopped or a failed run, and an ack counts only for this request"
# The SIGKILLed run above never released its lock.
backups 'rm -rf /backups/.lock'
docker exec "$MYSQL_CONTAINER" bash -c "mkdir -p $INSTANCE/worlds/w $INSTANCE/plugin_data && \
  echo seed > $INSTANCE/worlds/w/level.dat && echo seed > $INSTANCE/plugin_data/x.yml && echo seed > $INSTANCE/server.log"

# $1 a name (letters only), $2 held, free or absent, $3 a command run in the
# instance container once the stage is cleared. Sets state_rc and state_log.
state_run() {
  local id="state-$1"
  set_lock "$2"
  fence_reset
  docker exec "$MYSQL_CONTAINER" bash -c "$3"
  state_rc=0 state_log="$LOGS/run-$1.log"
  CAPTURE_TEST_REQUEST_ID="$id" CAPTURE_ACK_TIMEOUT_SECONDS=3 \
    run_backup 50 mysql selftest >"$state_log" 2>&1 || state_rc=$?
}

# $1 a set's name, $2 a volume. Prints the manifest's capture mode for it.
manifest_mode() { backups "sed -n 's/^capture_mode.$2: //p' /backups/$1/manifest.txt"; }

for lock in free absent; do
  state_run "lock$lock" "$lock" :
  set_name="$(sed -n 's|.*complete at /backups/||p' "$state_log")"
  if [ "$state_rc" = 0 ] && [ "$(manifest_mode "$set_name" world-a)" = stopped ] \
    && grep -q "volume world-a is down" "$state_log"; then
    pass "a $lock server.lock reads as a down instance: no ack is waited for and the manifest says stopped"
  else
    fail "expected a stopped volume for a $lock server.lock, got rc=$state_rc"; cat "$state_log"
  fi
done

for stale in otherdir wrongid; do
  case "$stale" in
    otherdir) dir=other ;;
    wrongid) dir="state-$stale" ;;
  esac
  before="$(set_count)"
  state_run "$stale" held "mkdir -p $INSTANCE/.capture/$dir && printf 'other\n1\n' > $INSTANCE/.capture/$dir/ack"
  if [ "$state_rc" != 0 ] && [ "$(set_count)" = "$before" ] && grep -q "has not acked" "$state_log"; then
    pass "a running instance whose ack is stale ($stale) fails the run and writes no set"
  else
    fail "expected a failed run and no set for a stale ack ($stale), got rc=$state_rc"; cat "$state_log"
  fi
done

section "a file changed during a tar: the tar's exit and the listings decide, with the write and the exit fixed by a tar shim"
TAR_SHIM="$LOGS/tar-shim"
cat >"$TAR_SHIM" <<'EOF'
#!/bin/bash
vol="" prev=""
for a in "$@"; do
  [ "$prev" != -C ] || { vol="$(basename "$a")"; break; }
  prev="$a"
done
n=$(( $(cat "/tmp/calls-$vol" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"/tmp/calls-$vol"
rc=0
/usr/bin/tar "$@" || rc=$?
[ "$vol" = "$SHIM_VOL" ] || exit "$rc"
echo "tar shim: call $n for $vol" >&2
if [ "$n" = 1 ] || [ "$SHIM_CALLS" = all ]; then
  for _ in $(seq 300); do [ -e "/tmp/go-$n" ] && break; sleep 0.2; done
  [ "$SHIM_EXIT" != TERM ] || kill -TERM $$
  exit "$SHIM_EXIT"
fi
exit "$rc"
EOF
chmod 755 "$TAR_SHIM"

# $1 a case key, $2 the script to run, backup.sh when empty. Runs it on world-a
# with the shim. After the image's own tar has read the volume, the shim waits
# while the instance container makes the case's write, then exits with the
# case's code. Sets sh_rc, sh_calls (the shim's calls for world-a), sh_mode (the
# manifest's mode for it) and sh_log.
shim_case() {
  local key="$1" script="${2:-$SCRIPT_DIR/backup.sh}" id="shim-$1" lock=absent code=0 calls=first write=: responder="" run n i set_name
  case "$key" in
    heldfree) lock=held code=1 write="echo x >> $INSTANCE/server.log; echo x >> $INSTANCE/plugin_data/x.yml" ;;
    heldlevel) lock=held calls=all write="echo x >> $INSTANCE/worlds/w/level.dat" ;;
    downlog) write="echo x >> $INSTANCE/server.log" ;;
    downplug) code=1 write="echo x >> $INSTANCE/plugin_data/x.yml" ;;
    exit2) code=2 ;;
    term) code=TERM ;;
  esac
  set_lock "$lock"
  fence_reset
  sh_log="$LOGS/run-$key.log"
  if [ "$lock" = held ]; then
    docker exec "$MYSQL_CONTAINER" bash -c "$INSTANCE_ACK" _ "$id" &
    responder=$!
  fi
  RUN_NAME="$RUN_NAME_SHIM" TAR_SHIM="$TAR_SHIM" SHIM_VOL=world-a SHIM_EXIT="$code" SHIM_CALLS="$calls" \
    BACKUP_SCRIPT="$script" CAPTURE_TEST_REQUEST_ID="$id" CAPTURE_ACK_TIMEOUT_SECONDS=20 \
    run_backup 50 mysql selftest >"$sh_log" 2>&1 &
  run=$!
  for n in 1 2; do
    [ "$n" = 1 ] || [ "$calls" = all ] || break
    for ((i = 0; i < 150; i++)); do
      grep -qF "tar shim: call $n for world-a" "$sh_log" && break
      kill -0 "$run" 2>/dev/null || break
      sleep 0.2
    done
    grep -qF "tar shim: call $n for world-a" "$sh_log" || break
    docker exec "$MYSQL_CONTAINER" bash -c "$write"
    docker exec "$RUN_NAME_SHIM" touch "/tmp/go-$n"
  done
  sh_rc=0
  wait "$run" || sh_rc=$?
  [ -z "$responder" ] || wait "$responder" || true
  sh_calls="$(grep -c 'tar shim: call [0-9]* for world-a' "$sh_log" || true)"
  set_name="$(sed -n 's|.*complete at /backups/||p' "$sh_log")"
  sh_mode=""
  [ -z "$set_name" ] || sh_mode="$(manifest_mode "$set_name" world-a)"
}

# $1 a case key. True when the last shim_case run did what the case requires.
shim_ok() {
  case "$1" in
    heldfree)
      [ "$sh_rc" = 0 ] && [ "$sh_calls" = 1 ] && [ "$sh_mode" = "held shim-heldfree" ] \
        && grep -q 'tar of volume world-a, held, exited 1' "$sh_log" \
        && ! grep -q 'changed during its tar' "$sh_log" ;;
    heldlevel)
      [ "$sh_rc" != 0 ] && [ "$sh_calls" = 2 ] \
        && [ "$(grep -c 'volume world-a after its tar: worlds/w/level.dat ' "$sh_log")" = 2 ] ;;
    downlog)
      [ "$sh_rc" = 0 ] && [ "$sh_calls" = 2 ] && [ "$sh_mode" = stopped ] \
        && grep -q 'volume world-a before its tar: server.log ' "$sh_log" ;;
    downplug)
      [ "$sh_rc" = 0 ] && [ "$sh_calls" = 2 ] && [ "$sh_mode" = stopped ] \
        && grep -q 'world-a is down and tar saw a file change' "$sh_log" ;;
    exit2)
      [ "$sh_rc" != 0 ] && [ "$sh_calls" = 1 ] \
        && grep -q 'tar of volume world-a exited 2 with its listing unchanged' "$sh_log" ;;
    term)
      [ "$sh_rc" != 0 ] && [ "$sh_calls" = 1 ] \
        && grep -q 'tar of volume world-a exited 143' "$sh_log" ;;
  esac
}

for key in heldfree heldlevel downlog downplug exit2 term; do
  shim_case "$key"
  if shim_ok "$key"; then
    pass "tar case $key: rc=$sh_rc, the shim saw $sh_calls call(s), mode '$sh_mode'"
  else
    fail "tar case $key did not behave as required: rc=$sh_rc calls=$sh_calls mode='$sh_mode'"; cat "$sh_log"
  fi
done

# $1 the mutant's name, $2 the case that guards the rule it removes.
mutate_case() {
  shim_case "$2" "$mutant"
  if shim_ok "$2"; then
    fail "the $1 mutant should turn the $2 case red"
  else
    pass "mutant $1: the $2 case goes red (rc=$sh_rc, calls=$sh_calls)"
  fi
}
mutate failexit1 1 -e 's/^  \[ "\$rc" -le 2 \] || fail/  [ "$rc" -eq 0 ] || fail/'
mutate_case failexit1 heldfree
mutate heldlog 1 -e 's/^  \[ "\$2" = held \] || paths+=(players server.log)$/  paths+=(players server.log)/'
mutate_case heldlog heldfree
mutate downnolog 1 -e 's/^  \[ "\$2" = held \] || paths+=(players server.log)$/  [ "$2" = held ] || paths+=(players)/'
mutate_case downnolog downlog
mutate keepexit1 1 -e 's/^  if \[ "\$rc" -eq 1 \] && \[ "\${mode\[\$name\]}" = stopped \]; then$/  if false; then/'
mutate_case keepexit1 downplug
mutate retryexit2 1 -e 's/^  \[ "\$rc" -ne 2 \] || fail .*$/  [ "$rc" -ne 2 ] || return 1/'
mutate_case retryexit2 exit2

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
printf 'all %s assertions passed: coordinated restorable backup, retention pruning, stale .partial sweep, concurrent-run lock, stale-lock sweep, lock ownership token, steal-vs-steal mutual exclusion, no lock visible during a claim, orphaned lock-discard sweep, discard-sweep-vs-still-alive-owner race, loud failure, the capture fence closing the copy under three mutants, failed runs lowering the fence, the lock test and stale acks, tar exits and writes under five mutants.\n' "$PASSES"
