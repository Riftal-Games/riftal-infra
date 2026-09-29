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
# A read-only login, provisioned with its role by
# ../migrations/run-migrations.sh from RIFTAL_DB_PASSWORD_BACKUP, so a backup
# run can never change the database it copies.
MYSQL_USER="${MYSQL_USER:-backup}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
MYSQL_DATABASE="${MYSQL_DATABASE:?MYSQL_DATABASE is required}"

BACKUP_ROOT="${BACKUP_ROOT:-/backups}"
WORLDS_DIR="${WORLDS_DIR:-/worlds}"
BACKUP_RETENTION="${BACKUP_RETENTION:-10}"
PARTIAL_MAX_AGE_MINUTES="${PARTIAL_MAX_AGE_MINUTES:-360}"
LOCK_MAX_AGE_MINUTES="${LOCK_MAX_AGE_MINUTES:-90}"

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

# Set before the trap below can possibly fire, since `set -u` turns a
# reference to an unset variable into its own error. Flipped to 1 only once
# this run's own mkdir below actually wins the lock, so a run that lost the
# race never removes a lock it does not hold. lock_owner is stamped by
# acquire_lock the moment that happens.
lock_acquired=0
lock_owner=""

LOCK_DIR="$BACKUP_ROOT/.lock"

# The scheduled loop only ever runs one invocation at a time, but
# deploy/README.md also documents a manual out-of-band run sharing this same
# BACKUP_ROOT. Without this, an overlapping manual run and scheduled run
# could each sweep the other's still-live .partial out from under it, or
# otherwise race on the same directory names and retention count
# (riftal-infra#166). The lock is scoped to BACKUP_ROOT, not to this script
# globally, so two different instances' backup volumes never contend on it.
# mkdir is atomic on any POSIX filesystem and needs nothing beyond coreutils,
# unlike flock, which is not installed in every image this script runs in.
# release_lock below removes the directory on the way out, including on the
# failure path, but only for the run that still actually owns it.
acquire_lock() {
  # PID alone repeats every time this runs as a container's PID 1, and a
  # timestamp alone can theoretically repeat across two runs racing the same
  # nanosecond; $ts already carries nanosecond precision for exactly that
  # reason, so pairing it with $$ costs nothing and removes any doubt. This
  # token is what a later run, sweeping this lock while this run is still
  # alive, makes unrecoverable for this run to reclaim: the new owner file
  # it writes no longer matches what this run wrote here.
  lock_owner="$$-$ts"

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    lock_acquired=1
    echo "$lock_owner" > "$LOCK_DIR/owner"
    return 0
  fi

  # The lock is only ever released by this script's own EXIT trap, which a
  # hard kill (OOM, a SIGKILL past the grace period, a host crash) bypasses
  # entirely, unlike flock, which the kernel releases on process death with
  # no equivalent here. A held lock this old cannot belong to a run still
  # working: a real run's own mysqldump-plus-tar duration is nowhere near
  # LOCK_MAX_AGE_MINUTES, so it is presumed abandoned and cleared. A sweep
  # racing the lock's own still-alive holder, rather than another sweeper,
  # is the case release_lock's ownership check exists for: this run
  # stamping a fresh owner token is what lets that holder discover, at its
  # own cleanup, that the lock is no longer its to remove.
  if [ -z "$(find "$LOCK_DIR" -maxdepth 0 -mmin "+$LOCK_MAX_AGE_MINUTES" 2>/dev/null)" ]; then
    fail "another run already holds the lock on $LOCK_DIR; refusing to run concurrently against the same BACKUP_ROOT"
  fi
  echo "backup $ts: $LOCK_DIR is older than ${LOCK_MAX_AGE_MINUTES}m, presumed abandoned by a run that never reached its own EXIT trap; clearing it and retrying" >&2
  # No-op outside deploy/selftest.sh's steal-vs-steal section. The window
  # this widens is real in every run, just a handful of syscalls wide and
  # not otherwise landable on demand: two sweepers must both pass the
  # staleness check above for the same lock before either has moved it.
  sleep "${STEAL_RACE_TEST_STALL_SECONDS:-0}"

  # Two sweepers can both reach this point for the same abandoned lock. A
  # bare `rm -rf` plus `mkdir` lets both proceed in turn: a second sweeper's
  # own `rm -rf`, run unconditionally, can land after the first sweeper's
  # `mkdir` and delete the fresh, already-claimed lock out from under it
  # instead of the original abandoned one (riftal-infra#175). Renaming
  # $LOCK_DIR itself out of the way, to a destination unique to this run,
  # is the first half of closing that: rename(2) needs its source to still
  # exist, and only one of two concurrent renames of the same source can
  # ever find it there, since whichever runs first consumes it. The loser's
  # `mv` fails with "No such file or directory" instead of silently
  # capturing whatever the winner puts at $LOCK_DIR next.
  discard_dir="$LOCK_DIR.discard.$lock_owner"
  if ! mv -T "$LOCK_DIR" "$discard_dir" 2>/dev/null; then
    fail "another run already holds the lock on $LOCK_DIR; refusing to run concurrently against the same BACKUP_ROOT"
  fi

  # No-op outside deploy/selftest.sh's discard-sweep-vs-still-alive-owner
  # section. Widens the window between the rename just above and the
  # staleness check just below, the same way STEAL_RACE_TEST_STALL_SECONDS
  # widens the window before the rename: a real run crosses this gap in a
  # handful of syscalls, too narrow to land a concurrent sweep of this run's
  # own discard directory against on demand otherwise.
  sleep "${DISCARD_RACE_TEST_STALL_SECONDS:-0}"

  # The rename alone is not the whole fix: it is blind to *what* it moved.
  # If the other sweeper wins the race to recreate $LOCK_DIR first, this
  # run's rename captures that brand new lock instead of finding it already
  # gone, since a directory rename does not care about its contents. A
  # rename changes ctime, never mtime, so the captured copy's age still
  # answers "was this the abandoned lock, or something recreated since": a
  # winner's fresh directory fails this same staleness test, and the loser
  # backs off by handing it straight back rather than deleting it.
  if [ -z "$(find "$discard_dir" -maxdepth 0 -mmin "+$LOCK_MAX_AGE_MINUTES" 2>/dev/null)" ]; then
    mv -T "$discard_dir" "$LOCK_DIR" 2>/dev/null || rm -rf "$discard_dir"
    fail "another run already holds the lock on $LOCK_DIR; refusing to run concurrently against the same BACKUP_ROOT"
  fi
  rm -rf "$discard_dir"

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    lock_acquired=1
    echo "$lock_owner" > "$LOCK_DIR/owner"
  else
    fail "another run already holds the lock on $LOCK_DIR; refusing to run concurrently against the same BACKUP_ROOT"
  fi
}

# Called from cleanup on every exit. Removes $LOCK_DIR only when the owner
# token still inside it is the one this run itself wrote in acquire_lock. A
# run whose lock was swept and reacquired by someone else while this run was
# still alive (possible for the first time now that a lock can be swept at
# all, riftal-infra#171) finds someone else's token there instead, and must
# leave that lock alone rather than deleting it out from under its new
# owner, silently reopening the exact concurrent-run overlap #166/#167 exist
# to prevent.
release_lock() {
  if [ "$lock_acquired" != 1 ]; then
    return 0
  fi
  current_owner="$(cat "$LOCK_DIR/owner" 2>/dev/null || true)"
  if [ "$current_owner" = "$lock_owner" ]; then
    rm -f "$LOCK_DIR/owner"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  else
    echo "backup $ts: $LOCK_DIR is no longer this run's lock (found owner '$current_owner', expected '$lock_owner'); a stale-lock sweep must have reclaimed it since, skipping removal rather than deleting the new owner's lock" >&2
  fi
}

# Fires on every exit, including an uncaught failure under `set -e`, so a
# broken run is never silent (acceptance criterion 5) and never leaves a
# half-written set behind for retention to count as a real backup.
cleanup() {
  status=$?
  release_lock
  if [ "$status" -ne 0 ]; then
    echo "backup $ts: failed, exit $status" >&2
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

mkdir -p "$BACKUP_ROOT"

# Test-only entry points so deploy/selftest.sh can drive acquire_lock and
# release_lock independently of a full mysqldump-plus-tar run: the only way
# to hold a lock "still alive" across a second run sweeping it, without
# actually waiting out a real backup. Nothing outside the self-test ever
# invokes backup.sh with an argument.
case "${1:-}" in
  __test_acquire_lock)
    acquire_lock
    echo "$lock_owner"
    trap - EXIT
    exit 0
    ;;
  __test_release_lock)
    lock_acquired=1
    lock_owner="$2"
    release_lock
    trap - EXIT
    exit 0
    ;;
esac

acquire_lock

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

# A $LOCK_DIR.discard.* left on disk here is a stale steal's rename target
# from a run killed between winning that rename and its own follow-up rm -rf
# (riftal-infra#175, riftal-infra#183). Unlike .partial above, no age check
# applies: acquire_lock only returns, as it just has for this run, once its
# own discard directory has been renamed back or removed, so this run's own
# discard directory is never still here to sweep. A discard directory left
# by a different, still-running process is safe to sweep too: that process's
# staleness check on its own now-missing discard directory finds nothing, so
# it takes the existing "hand it back" branch and fails with the same
# "another run already holds the lock" error every other contention path
# already produces.
mapfile -t stale_discards < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -name '.lock.discard.*')
for stale in "${stale_discards[@]}"; do
  echo "backup $ts: removing orphaned $stale, a discarded lock left behind by a run killed mid-cleanup"
  rm -rf "$stale"
done

mkdir -p "$tmp_dir/worlds"

echo "backup $ts: dumping database $MYSQL_DATABASE from $MYSQL_HOST:$MYSQL_PORT"
# Tablespace definitions are server-wide and need PROCESS, which the backup
# login does not hold; a single-schema restore never recreates them anyway.
MYSQL_PWD="$MYSQL_PASSWORD" mysqldump --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
  --user="$MYSQL_USER" --single-transaction --routines --triggers --no-tablespaces \
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
#
# `.lock` is excluded for a sharper reason: it sorts before every
# timestamp-named backup directory, so left in, it is always the first
# thing pruned once excess > 0, tearing down this run's own lock mid-run
# instead of via the EXIT trap and reopening the exact overlap window the
# lock exists to close (riftal-infra#166).
#
# `.lock.discard.*` is a stale steal's discarded former lock, orphaned only
# if that run was killed between winning the rename and its own follow-up
# `rm -rf` (riftal-infra#175). It is swept above on the next successful lock
# acquisition, but until then it is never a backup, and left uncounted here
# for the same reason `.partial` is.
mapfile -t existing < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -not -name '*.partial' -not -name '.lock' -not -name '.lock.discard.*' | sort)
excess=$(( ${#existing[@]} - BACKUP_RETENTION ))
if [ "$excess" -gt 0 ]; then
  for old in "${existing[@]:0:excess}"; do
    echo "backup $ts: pruning $old"
    rm -rf "$old"
  done
fi
