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
#
# A running instance is never tarred live. The run asks every instance to hold
# one tick through a request on CAPTURE_DIR, and tars each volume either at
# that held tick or, when its instance is down, as it lies, then proves the
# volume did not change during its tar (riftal-pm docs/decisions, ADR 015).
#
# The capture fence row in the shared database is raised before the dump and
# lowered only after the last volume is verified, so a commit-first flow
# cannot copy an item between the dump and a tick (ADR 027).
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:?MYSQL_HOST is required}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
# A login granted SELECT, SHOW VIEW and TRIGGER on the schema and global
# SHOW_ROUTINE, provisioned with its role by ../migrations/run-migrations.sh
# from RIFTAL_DB_PASSWORD_BACKUP. What it is denied and what it can still do
# are in README.md, The dump login.
MYSQL_USER="${MYSQL_USER:-backup}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
MYSQL_DATABASE="${MYSQL_DATABASE:?MYSQL_DATABASE is required}"

BACKUP_ROOT="${BACKUP_ROOT:-/backups}"
WORLDS_DIR="${WORLDS_DIR:-/worlds}"
BACKUP_RETENTION="${BACKUP_RETENTION:-10}"
PARTIAL_MAX_AGE_MINUTES="${PARTIAL_MAX_AGE_MINUTES:-360}"
LOCK_MAX_AGE_MINUTES="${LOCK_MAX_AGE_MINUTES:-90}"
CAPTURE_DIR="${CAPTURE_DIR:-/capture}"
CAPTURE_ACK_TIMEOUT_SECONDS="${CAPTURE_ACK_TIMEOUT_SECONDS:-60}"
CAPTURE_HOLD_MAX_SECONDS="${CAPTURE_HOLD_MAX_SECONDS:-900}"
CAPTURE_FENCE_MAX_SECONDS="${CAPTURE_FENCE_MAX_SECONDS:-1800}"

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

# The fence must outlast the dump plus the hold, and 3600 is the bound
# capture_fence_raise itself enforces (ADR 027 item 5).
{ [[ "$CAPTURE_FENCE_MAX_SECONDS" =~ ^[0-9]+$ ]] \
  && [ "$CAPTURE_FENCE_MAX_SECONDS" -gt "$CAPTURE_HOLD_MAX_SECONDS" ] \
  && [ "$CAPTURE_FENCE_MAX_SECONDS" -le 3600 ]; } \
  || fail "CAPTURE_FENCE_MAX_SECONDS '$CAPTURE_FENCE_MAX_SECONDS' must be above CAPTURE_HOLD_MAX_SECONDS ($CAPTURE_HOLD_MAX_SECONDS) and at most 3600"

# Set before the trap below can possibly fire, since `set -u` turns a
# reference to an unset variable into its own error. Flipped to 1 only once
# this run's own claim_lock below actually wins the lock, so a run that lost
# the race never removes a lock it does not hold. lock_owner is set by
# acquire_lock before that claim is attempted.
lock_acquired=0
lock_owner=""
request_written=0
fence_raised=0

# RiftalCapture ignores a request whose id falls outside its grammar
# (images/plugins/RiftalCapture.php, CaptureRequest::parse), which would
# surface only as an ack timeout on every running instance. $ts always fits;
# CAPTURE_TEST_REQUEST_ID is set only by a self-test.
request_id="${CAPTURE_TEST_REQUEST_ID:-$ts}"

# Per volume: held or stopped, the first listing, and the descriptor holding a
# free server.lock until that volume is verified.
declare -A mode=() first=() lock_fd=()

LOCK_DIR="$BACKUP_ROOT/.lock"

# The scheduled loop only ever runs one invocation at a time, but
# deploy/README.md also documents a manual out-of-band run sharing this same
# BACKUP_ROOT. Without this, an overlapping manual run and scheduled run
# could each sweep the other's still-live .partial out from under it, or
# otherwise race on the same directory names and retention count
# (riftal-infra#166). The lock is scoped to BACKUP_ROOT, not to this script
# globally, so two different instances' backup volumes never contend on it.
# A directory rename is atomic on any POSIX filesystem and needs nothing
# beyond coreutils, unlike flock, which is not installed in every image
# this script runs in.
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

  if claim_lock; then
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
  # Defaults to 0, and is set only by deploy/selftest.sh.
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

  # Defaults to 0, and is set only by deploy/selftest.sh.
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

  claim_lock || fail "another run already holds the lock on $LOCK_DIR; refusing to run concurrently against the same BACKUP_ROOT"
}

# Were $LOCK_DIR created first and stamped second, a sweeper that passed its
# staleness check earlier could rename it away between the two: the stamp
# fails, the sweeper hands back a lock nobody owns, both runs lose, and that
# ownerless lock blocks every run for LOCK_MAX_AGE_MINUTES
# (riftal-infra#491). So the lock is built, owner file and all, under this
# run's own discard name, which retention and the orphan sweep already
# handle, and only then renamed into place. rename(2) onto an existing
# directory succeeds only if that directory is empty, so a lock that always
# carries its owner file is one no second claim can replace. An empty .lock
# made by hand is the exception. The existence check narrows, but does not
# close, the window in which the rename could silently replace one; outside
# it, acquire_lock judges its age and logs any sweep as for any other lock.
claim_lock() {
  # Equal to acquire_lock's discard name. That is safe only because
  # acquire_lock removes its discard directory before its second claim.
  staging_dir="$LOCK_DIR.discard.$lock_owner"
  # CLAIM_RACE_TEST_STALL_SECONDS below defaults to 0, and is set only by
  # deploy/selftest.sh.
  if mkdir "$staging_dir" 2>/dev/null \
    && { echo "$lock_owner" > "$staging_dir/owner"; } 2>/dev/null \
    && [ ! -e "$LOCK_DIR" ] \
    && sleep "${CLAIM_RACE_TEST_STALL_SECONDS:-0}" \
    && mv -T "$staging_dir" "$LOCK_DIR" 2>/dev/null; then
    lock_acquired=1
    return 0
  fi
  rm -rf "$staging_dir"
  return 1
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

# ADR 015 item 3.7, and on every exit. Only this run's own request is
# deleted, so a run whose lock was swept never ends another run's hold.
release_request() {
  if [ "$request_written" = 1 ] \
    && [ "$(cut -d' ' -f1 "$CAPTURE_DIR/request" 2>/dev/null)" = "$request_id" ]; then
    rm -f "$CAPTURE_DIR/request"
  fi
  request_written=0
}

# $1 the SQL. Runs as the dump login, which holds EXECUTE on the two fence
# procedures and SELECT on capture_fence and nothing that writes a table.
fence_sql() {
  MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" --batch --skip-column-names "$MYSQL_DATABASE" -e "$1"
}

# ADR 027 item 5.2. $request_id is inside RiftalCapture's grammar, which
# holds no quote. fence_raised is set first: a raise that committed but whose
# answer was lost is still this run's to lower, and lowering by id is a no-op
# on a fence this run does not hold.
raise_fence() {
  local outcome
  fence_raised=1
  outcome="$(fence_sql "CALL capture_fence_raise('$request_id', $CAPTURE_FENCE_MAX_SECONDS, @o); SELECT @o")" \
    || fail "could not raise the capture fence; is migration 0027 applied and EXECUTE granted to the dump login? no dump is taken"
  [ "$outcome" = raised ] \
    || fail "capture fence raise answered '$outcome', another run's lease is live; no dump is taken"
  echo "backup $ts: capture fence raised as $request_id for ${CAPTURE_FENCE_MAX_SECONDS}s"
}

# ADR 027 items 5.6 and 5.7's trap. A lower that fails is logged and the
# lease ends the fence.
lower_fence() {
  local outcome
  [ "$fence_raised" = 1 ] || return 0
  if outcome="$(fence_sql "CALL capture_fence_lower('$request_id', @o); SELECT @o" 2>&1)"; then
    fence_raised=0
    echo "backup $ts: capture fence $request_id $outcome"
  else
    echo "backup $ts: could not lower capture fence $request_id, its ${CAPTURE_FENCE_MAX_SECONDS}s lease ends it: $outcome" >&2
  fi
}

# ADR 027 item 5.5. The lease is fixed at the raise and one run holds it, so a
# live lease here covers every moment from the dump to the last tick.
check_fence_lease() {
  local live
  live="$(fence_sql "SELECT COUNT(*) FROM capture_fence WHERE id = 1 AND request_id = '$request_id' AND raised_until > UTC_TIMESTAMP(3)")" \
    || fail "could not read the capture fence, no set is written"
  [ "$live" = 1 ] || fail "capture fence lapsed before the last volume was verified, no set is written"
}

# Written through a rename, so an instance never reads half a request. The
# deadline is the lease: a run that dies without its trap ends no later.
write_request() {
  mkdir -p "$CAPTURE_DIR"
  printf '%s %s\n' "$request_id" "$(( $(date +%s) + CAPTURE_HOLD_MAX_SECONDS ))" \
    > "$CAPTURE_DIR/request.tmp"
  request_written=1
  mv -f "$CAPTURE_DIR/request.tmp" "$CAPTURE_DIR/request"
}

# ADR 015 item 5: name, size and mtime, to the fraction of a second because on
# a held volume this listing alone guards worlds/ and .capture/, and whole
# seconds would miss a same-size rewrite. A held volume lists only what holds
# an item or marks a restart; its stage stands in for players/, and its
# server.log holds no item. A down volume adds both, since a start appends to
# server.log before any player joins. Absent paths list as nothing.
list_volume() {
  local paths=(worlds .capture server.lock)
  [ "$2" = held ] || paths+=(players server.log)
  { (cd "$1" && find "${paths[@]}" -printf '%p %s %T@\n' 2>/dev/null) || true; } | LC_ALL=C sort
}

# $1 a listing; $2 a path within the volume. True when the listing shows it.
listed() {
  awk -v p="$2" '$1 == p { found = 1 } END { exit !found }' <<<"$1"
}

# Every entry of listing $1 that listing $2 lacks, one per line.
entries_missing() {
  LC_ALL=C comm -23 <(printf '%s' "${1:+$1$'\n'}") <(printf '%s' "${2:+$2$'\n'}")
}

# The ack is two lines: the request id, then the server's start time in whole
# microseconds (RiftalCapture.php, Stage). A restart writes a new second line.
acked() {
  local lines=()
  mapfile -t lines 2>/dev/null < "$1/.capture/$request_id/ack" || return 1
  [ "${#lines[@]}" -eq 2 ] && [ "${lines[0]}" = "$request_id" ] && [[ "${lines[1]}" =~ ^[0-9]+$ ]]
}

unlock_volume() {
  local fd="${lock_fd[$1]:-}"
  if [ -n "$fd" ]; then
    exec {fd}<&-
    unset 'lock_fd[$1]'
  fi
}

# ADR 015 items 3.4 and 6. Core holds a shared flock on server.lock while it
# runs. A held lock means a running instance, which must ack. A free one
# means a down instance: the exclusive lock taken here, on a descriptor kept
# open until the volume is verified, blocks any start until then. An absent
# one means down only if the listing taken at once shows neither the lock nor
# this run's ack; otherwise the volume is tested again. Every wait, an absent
# lock beside a stale ack included, ends at CAPTURE_ACK_TIMEOUT_SECONDS.
await_volume() {
  local name="$1" vol="$WORLDS_DIR/$1" fd listing why
  local deadline=$(( $(date +%s) + CAPTURE_ACK_TIMEOUT_SECONDS ))
  # On a retry this run may still hold the volume's exclusive lock from its
  # first try. flock locks each open file description, so the test below would
  # then find this run's own lock and wait out the ack timeout.
  unlock_volume "$name"
  while :; do
    if [ -e "$vol/server.lock" ] && exec {fd}<"$vol/server.lock"; then
      if flock -xn "$fd"; then
        lock_fd[$name]="$fd"
        mode[$name]=stopped
        first[$name]="$(list_volume "$vol" stopped)"
        echo "backup $ts: volume $name is down, its server.lock is free"
        return 0
      fi
      exec {fd}<&-
      if acked "$vol"; then
        mode[$name]=held
        echo "backup $ts: volume $name is held for request $request_id"
        return 0
      fi
      why="its instance is running and has not acked request $request_id; is RiftalCapture loaded?"
    else
      listing="$(list_volume "$vol" stopped)"
      if ! listed "$listing" server.lock && ! listed "$listing" ".capture/$request_id/ack"; then
        mode[$name]=stopped
        first[$name]="$listing"
        echo "backup $ts: volume $name is down, it has no server.lock"
        return 0
      fi
      why="it shows a server.lock or an ack for request $request_id that no running instance holds"
    fi
    [ "$(date +%s)" -lt "$deadline" ] \
      || fail "volume $name: after ${CAPTURE_ACK_TIMEOUT_SECONDS}s $why"
    sleep 1
  done
}

# ADR 015 items 4 and 5. A held volume is tarred without its live players/,
# with the stage from its held tick stored as players/ in its place. False,
# with the tar discarded, when the volume must be tarred again.
#
# GNU tar exits 1 under --create when a file changed while it was read, and 2
# on a fatal error. A held instance keeps writing files that hold no item, so
# there exit 1 is left to the listings; nothing may write a down volume, so
# there it is a change. Exit 2 with a changed listing is a restart removing
# the stage, which a retry fixes; with an unchanged one, a retry would not.
capture_volume() {
  local name="$1" vol="$WORLDS_DIR/$1" out="$tmp_dir/worlds/$1.tar.gz" after rc=0
  if [ "${mode[$name]}" = held ]; then
    first[$name]="$(list_volume "$vol" held)"
    if ! listed "${first[$name]}" ".capture/$request_id/ack"; then
      echo "backup $ts: volume $name lost its ack for request $request_id before its tar"
      return 1
    fi
    tar -czf "$out" --anchored --exclude=./players --exclude=./.capture \
      -C "$vol" . -C "$vol/.capture/$request_id" players || rc=$?
  else
    tar -czf "$out" --anchored --exclude=./.capture -C "$vol" . || rc=$?
  fi
  echo "backup $ts: tar of volume $name, ${mode[$name]}, exited $rc"
  [ "$rc" -le 2 ] || fail "tar of volume $name exited $rc, no set is written"
  after="$(list_volume "$vol" "${mode[$name]}")"
  unlock_volume "$name"
  if [ "$after" != "${first[$name]}" ]; then
    echo "backup $ts: volume $name changed during its tar"
    entries_missing "${first[$name]}" "$after" | sed "s|^|backup $ts: volume $name before its tar: |"
    entries_missing "$after" "${first[$name]}" | sed "s|^|backup $ts: volume $name after its tar: |"
    rm -f "$out"
    return 1
  fi
  [ "$rc" -ne 2 ] || fail "tar of volume $name exited 2 with its listing unchanged, no set is written"
  if [ "$rc" -eq 1 ] && [ "${mode[$name]}" = stopped ]; then
    echo "backup $ts: volume $name is down and tar saw a file change"
    rm -f "$out"
    return 1
  fi
}

# Fires on every exit, including an uncaught failure under `set -e`, so a
# broken run is never silent (acceptance criterion 5) and never leaves a
# half-written set behind for retention to count as a real backup.
cleanup() {
  status=$?
  release_request
  lower_fence
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

# A $LOCK_DIR.discard.* left on disk here is a stale steal's rename target,
# or a claim_lock staging directory, from a run killed before it renamed or
# removed that directory (riftal-infra#175, riftal-infra#183). Unlike
# .partial above, no age check applies: acquire_lock only returns, as it just
# has for this run, once its own discard directory has been renamed away or
# removed, so this run's own discard directory is never still here to sweep.
# A discard directory left by a different, still-running process is safe to
# sweep too: a stealer's staleness check on its now-missing discard directory
# finds nothing, so it takes the existing "hand it back" branch, and a
# claimer's stamp or rename finds nothing to act on, so claim_lock fails.
# Either way it fails with the same "another run already holds the lock"
# error every other contention path already produces.
mapfile -t stale_discards < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -name '.lock.discard.*')
for stale in "${stale_discards[@]}"; do
  echo "backup $ts: removing orphaned $stale, a discarded lock left behind by a run killed mid-cleanup"
  rm -rf "$stale"
done

mkdir -p "$tmp_dir/worlds"

# The id goes into SQL, and no instance would ack one outside the grammar.
[[ "$request_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
  || fail "request id '$request_id' is outside RiftalCapture's grammar, no instance would ack it"

# The fence goes up before the dump and comes down only after the last volume
# is verified, so no commit-first flow can commit between the dump and the
# last tick and then deliver (ADR 027 item 5).
raise_fence

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

# The dump comes before the request: a flow that takes an item from a player
# and then commits in MySQL can then only be lost by a restore, never copied
# (ADR 015, Why).
#
# Defaults to 0, and is set only by the self-tests, to act between the dump
# and the request.
sleep "${FENCE_TEST_STALL_SECONDS:-0}"
echo "backup $ts: requesting a held capture $request_id, lease ${CAPTURE_HOLD_MAX_SECONDS}s"
write_request

for world in "${worlds[@]}"; do
  await_volume "$(basename "$world")"
done

# Defaults to 0, and is set only by a proof run that acts between the acks
# and the tars.
sleep "${CAPTURE_TEST_STALL_SECONDS:-0}"

# A volume that changed during its tar is waited on again, now under the
# held request, and tarred once more. A second change fails the run.
for world in "${worlds[@]}"; do
  name="$(basename "$world")"
  echo "backup $ts: snapshotting world volume $name, ${mode[$name]}"
  if ! capture_volume "$name"; then
    await_volume "$name"
    capture_volume "$name" || fail "volume $name changed during its tar twice, no set is written"
  fi
done

check_fence_lease
release_request
lower_fence

{
  echo "timestamp: $ts"
  echo "mysql_database: $MYSQL_DATABASE"
  echo "mysql_dump_bytes: $(wc -c < "$tmp_dir/mysql.sql")"
  echo "world_volumes:"
  for world in "${worlds[@]}"; do
    name="$(basename "$world")"
    echo "  - $name: $(wc -c < "$tmp_dir/worlds/$name.tar.gz") bytes"
  done
  for world in "${worlds[@]}"; do
    name="$(basename "$world")"
    if [ "${mode[$name]}" = held ]; then
      echo "capture_mode.$name: held $request_id"
    else
      echo "capture_mode.$name: stopped"
    fi
  done
  echo "capture_fence: $request_id"
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
# `.lock.discard.*` is a stale steal's rename target or a claim_lock staging
# directory, orphaned only if its run was killed before it renamed or removed
# that directory (riftal-infra#175). It is swept above on the next successful
# lock acquisition, but until then it is never a backup, and left uncounted
# here for the same reason `.partial` is.
mapfile -t existing < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -not -name '*.partial' -not -name '.lock' -not -name '.lock.discard.*' | sort)
excess=$(( ${#existing[@]} - BACKUP_RETENTION ))
if [ "$excess" -gt 0 ]; then
  for old in "${existing[@]:0:excess}"; do
    echo "backup $ts: pruning $old"
    rm -rf "$old"
  done
fi
