#!/usr/bin/env bash
# One coordinated backup run: a mysqldump of the shared database plus a tar
# of every instance's world volume, landing together under one timestamped
# directory so a restore pairs the two at the same point in time
# (docs/specs/008-backup-and-restore.md, acceptance criterion 1).
#
# World volumes are discovered by listing WORLDS_DIR's subdirectories rather
# than by a fixed count or a hardcoded name list, so an instance split
# (CLAUDE.md hard rule 5) needs only a mount added where this script is run
# from, never a change here. compose.yaml's `backup` service is what decides
# which volumes appear under WORLDS_DIR.
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:?MYSQL_HOST is required}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
MYSQL_DATABASE="${MYSQL_DATABASE:?MYSQL_DATABASE is required}"

BACKUP_ROOT="${BACKUP_ROOT:-/backups}"
WORLDS_DIR="${WORLDS_DIR:-/worlds}"
BACKUP_RETENTION="${BACKUP_RETENTION:-10}"
PARTIAL_MAX_AGE_MINUTES="${PARTIAL_MAX_AGE_MINUTES:-360}"

# Nanosecond precision, not just seconds, so two runs started close together
# (a manual run and the loop, or two runs in a test) never collide on the
# same directory name. A collision would make the second run's `mv` land
# inside the first run's directory instead of replacing it, since `mv` onto
# an existing directory nests rather than errors.
ts="$(date -u +%Y%m%dT%H%M%S%NZ)"
set_dir="$BACKUP_ROOT/$ts"
tmp_dir="$set_dir.partial"

fail() {
  echo "backup $ts: $1" >&2
  exit 1
}

# Fires on every exit, including an uncaught failure under `set -e`, so a
# broken run is never silent (acceptance criterion 5) and never leaves a
# half-written set behind for retention to count as a real backup.
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "backup $ts: failed, exit $status" >&2
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

mkdir -p "$BACKUP_ROOT"

# The scheduled loop only ever runs one invocation at a time, but
# deploy/README.md also documents a manual out-of-band run sharing this same
# BACKUP_ROOT. Without this, an overlapping manual run and scheduled run
# could each sweep the other's still-live .partial out from under it, or
# otherwise race on the same directory names and retention count
# (riftal-infra#166). The lock is scoped to BACKUP_ROOT, not to this script
# globally, so two different instances' backup volumes never contend on it.
# It is held until this process exits, since the fd stays open for the
# process's whole life and the kernel drops the flock when the fd closes,
# so no separate release step is needed even on the failure path through
# `cleanup` above.
LOCK_FILE="$BACKUP_ROOT/.lock"
exec {lock_fd}>"$LOCK_FILE"
flock -n "$lock_fd" || fail "another run already holds the lock on $LOCK_FILE; refusing to run concurrently against the same BACKUP_ROOT"

# A `.partial` older than the threshold belonged to a run that is never
# coming back to finish it (OOM, a SIGKILL past the grace period, a host
# crash): retention deliberately leaves every `.partial` alone since a fresh
# one might still be a real run in progress, so nothing else ever cleared
# these, and they accumulated silently (riftal-infra#151). A fresh one
# (including this run's own, just about to be created below) is always
# younger than the threshold and is never touched by this.
mapfile -t stale_partials < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -name '*.partial' -mmin "+$PARTIAL_MAX_AGE_MINUTES")
for stale in "${stale_partials[@]}"; do
  echo "backup $ts: removing stale $stale, a .partial older than ${PARTIAL_MAX_AGE_MINUTES}m, presumed abandoned"
  rm -rf "$stale"
done

mkdir -p "$tmp_dir/worlds"

echo "backup $ts: dumping database $MYSQL_DATABASE from $MYSQL_HOST:$MYSQL_PORT"
MYSQL_PWD="$MYSQL_PASSWORD" mysqldump --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
  --user="$MYSQL_USER" --single-transaction --routines --triggers \
  "$MYSQL_DATABASE" > "$tmp_dir/mysql.sql"
[ -s "$tmp_dir/mysql.sql" ] || fail "mysqldump produced an empty file"

shopt -s nullglob
worlds=("$WORLDS_DIR"/*/)
shopt -u nullglob
[ "${#worlds[@]}" -gt 0 ] || fail "no world volumes found under $WORLDS_DIR"

for world in "${worlds[@]}"; do
  name="$(basename "$world")"
  echo "backup $ts: snapshotting world volume $name"
  tar -C "$world" -czf "$tmp_dir/worlds/$name.tar.gz" .
done

{
  echo "timestamp: $ts"
  echo "mysql_database: $MYSQL_DATABASE"
  echo "mysql_dump_bytes: $(wc -c < "$tmp_dir/mysql.sql")"
  echo "world_volumes:"
  for world in "${worlds[@]}"; do
    name="$(basename "$world")"
    echo "  - $name: $(wc -c < "$tmp_dir/worlds/$name.tar.gz") bytes"
  done
} > "$tmp_dir/manifest.txt"

mv "$tmp_dir" "$set_dir"
echo "backup $ts: complete at $set_dir"

echo "backup $ts: applying retention, keeping the last $BACKUP_RETENTION"
# A `.partial` directory is never a backup, complete or not: this run's own
# has already been renamed away by the `mv` above, so anything still named
# `.partial` here is a stale leftover from a run that never reached that
# `mv` (OOM, a SIGKILL past the grace period, a host crash). Retention
# leaves it alone rather than pruning it, the same way it leaves any other
# non-backup file under BACKUP_ROOT alone.
mapfile -t existing < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -not -name '*.partial' | sort)
excess=$(( ${#existing[@]} - BACKUP_RETENTION ))
if [ "$excess" -gt 0 ]; then
  for old in "${existing[@]:0:excess}"; do
    echo "backup $ts: pruning $old"
    rm -rf "$old"
  done
fi
