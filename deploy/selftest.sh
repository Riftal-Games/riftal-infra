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
EXPECTED_ASSERTIONS=18
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

run_backup() {
  local retention="$1" host="$2" password="$3" partial_max_age="${4:-360}"
  timeout 60 docker run --rm --network "$NETWORK" \
    -v "$SCRIPT_DIR/backup.sh:/deploy/backup.sh:ro" \
    -v "$BACKUPS_VOL:/backups" \
    -v "$WORLD_A_VOL:/worlds/world-a:ro" -v "$WORLD_B_VOL:/worlds/world-b:ro" \
    -e MYSQL_HOST="$host" -e MYSQL_USER=root -e MYSQL_PASSWORD="$password" \
    -e MYSQL_DATABASE=riftal_selftest -e BACKUP_RETENTION="$retention" \
    -e PARTIAL_MAX_AGE_MINUTES="$partial_max_age" \
    mysql:8 bash /deploy/backup.sh
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
printf 'all %s assertions passed: coordinated restorable backup, retention pruning, stale .partial sweep, loud failure.\n' "$PASSES"
