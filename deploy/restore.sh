#!/usr/bin/env bash
# Rebuilds the shared MySQL database and every instance's world volume from
# one backup set produced by backup.sh (docs/specs/008-backup-and-restore.md,
# acceptance criterion 3).
#
# BACKUP_SET names one specific run's directory rather than "the latest",
# because the operator restoring after a bad deploy or a corrupted world is
# often trying to get back to a point *before* the most recent backup, and a
# default that silently picks "latest" can restore straight back into the
# bad state.
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:?MYSQL_HOST is required}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
MYSQL_DATABASE="${MYSQL_DATABASE:?MYSQL_DATABASE is required}"

BACKUP_SET="${BACKUP_SET:?BACKUP_SET is required: the path to one directory produced by backup.sh, e.g. /backups/20260928T120000000000000Z}"
WORLDS_DIR="${WORLDS_DIR:-/worlds}"

fail() {
  echo "restore $BACKUP_SET: $1" >&2
  exit 1
}

[ -d "$BACKUP_SET" ] || fail "no such backup set directory"
[ -s "$BACKUP_SET/mysql.sql" ] || fail "missing or empty mysql.sql"
[ -d "$BACKUP_SET/worlds" ] || fail "missing worlds/ directory"

shopt -s nullglob
world_tars=("$BACKUP_SET"/worlds/*.tar.gz)
shopt -u nullglob
[ "${#world_tars[@]}" -gt 0 ] || fail "no world tars found under $BACKUP_SET/worlds"

# Every volume's capture mode must be on record (ADR 015 item 7). A set
# written before capture modes existed, or one whose manifest lost a volume's
# line, was not taken at one held tick, so its volumes can disagree with each
# other and with the dump.
has_mode() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "capture_mode.$1: stopped") return 0 ;;
      "capture_mode.$1: held "?*) [[ "${line#"capture_mode.$1: held "}" != *" "* ]] && return 0 ;;
    esac
  done <"$BACKUP_SET/manifest.txt"
  return 1
}
captured=1
if [ -r "$BACKUP_SET/manifest.txt" ]; then
  for tar_file in "${world_tars[@]}"; do
    has_mode "$(basename "$tar_file" .tar.gz)" || captured=0
  done
else
  captured=0
fi
if [ "$captured" = 0 ]; then
  if [ "${ALLOW_UNCAPTURED_SET:-}" != "1" ]; then
    fail "refused: the manifest has no valid capture_mode line for every world volume, so the volumes may not share one tick; set ALLOW_UNCAPTURED_SET=1 to restore it anyway"
  fi
  echo "restore $BACKUP_SET: WARNING: ALLOW_UNCAPTURED_SET=1, restoring a set whose volumes may not share one tick" >&2
fi

# A set without the line was taken before the capture fence existed, so its
# dump can hold a commit-first delivery whose item a held volume also holds
# (docs/decisions/027, item 6). Refused before anything is touched unless the
# operator accepts that copy.
fenced=0
if [ -r "$BACKUP_SET/manifest.txt" ] && grep -Eq '^capture_fence: [^ ]+$' "$BACKUP_SET/manifest.txt"; then
  fenced=1
fi
if [ "$fenced" = 0 ] && [ "${ALLOW_UNFENCED_SET:-}" != "1" ]; then
  fail "refused: the manifest has no capture_fence line, so this set may hold an item twice; set ALLOW_UNFENCED_SET=1 to restore it anyway"
fi

# Listed, not extracted: a truncated or otherwise corrupt tar fails `tar -t`
# the same way it would fail `tar -x`, without writing anything. Checked for
# every world before the database or any target directory is touched, so one
# bad tar aborts the whole restore instead of being discovered only after
# earlier worlds in the set have already been cleared and left neither
# restored nor in their pre-restore state.
echo "restore $BACKUP_SET: validating ${#world_tars[@]} world tar(s) before touching anything"
for tar_file in "${world_tars[@]}"; do
  name="$(basename "$tar_file" .tar.gz)"
  tar -tzf "$tar_file" >/dev/null || fail "world tar for $name ($tar_file) failed integrity check, aborting before clearing anything"
done

# A target that is no mount would take its tar into this container's own
# filesystem, where it vanishes on exit, while the database is rolled back and
# the run reports success: the two then disagree about every item. Refused
# before the database, a server.lock or any directory is touched.
command -v mountpoint >/dev/null || fail "refused: mountpoint is not installed, so a missing volume mount cannot be detected; run this in the backup image"
unmounted=""
for tar_file in "${world_tars[@]}"; do
  name="$(basename "$tar_file" .tar.gz)"
  mountpoint -q "$WORLDS_DIR/$name" || unmounted="$unmounted $name"
done
[ -z "$unmounted" ] || fail "refused: volume(s)$unmounted not mounted under $WORLDS_DIR, so the database would be rebuilt without its level; add a -v line for each"

sql() {
  MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" -N -B -e "$1"
}

# A connected instance would keep writing through the drop and the volume
# clearing, into tables and files the restore is about to replace. This reads
# the moment of the check only: stopping every instance first is the operator's
# step, and this catches one that was missed.
#
# Without PROCESS the processlist shows only this account's own threads, so the
# count below would read 0 whatever is connected. SHOW GRANTS with no FOR lists
# the session's privileges with its active roles expanded, so it is read in the
# same session as the count, and a granted role that is not active refuses.
#
# The processlist is empty when the server runs with performance_schema off,
# and could be blind for a reason not foreseen here, so its count is trusted
# only once it shows this connection's own thread.
#
# Every session counts whatever its default database, because any of them can
# write here by qualified name.
probe="$(sql "SHOW GRANTS; SELECT 'counts', COALESCE(SUM(ID = CONNECTION_ID()), 0), COALESCE(SUM(COMMAND <> 'Daemon'
  AND ID <> CONNECTION_ID()), 0) FROM performance_schema.processlist")"
grep -Eq '^GRANT ([^,]+, )*(PROCESS|ALL PRIVILEGES)(, [^,]+)* ON \*\.\* TO ' <<<"$probe" \
  || fail "refused: $MYSQL_USER lacks PROCESS, directly or through an active role, so it cannot see every session"
read -r _ own sessions < <(grep '^counts' <<<"$probe") || true
[ "$own" = "1" ] || fail "refused: the processlist does not show this session, so it cannot see the others; is performance_schema off?"
[ "$sessions" = "0" ] || fail "refused: $sessions other session(s) are connected to $MYSQL_HOST:$MYSQL_PORT; close every other connection, instances first"

# A restore under a running instance is overwritten by its next save. Core
# holds a shared flock on server.lock while it runs (ADR 015 item 6), so an
# exclusive try-lock finds a running instance on this host even before it has
# opened a database session, which the processlist cannot see. The processlist
# sees the session of an instance on any host, and an instance on another host
# cannot mount these volumes. Pass 1 only reads, so a refusal has written
# nothing. Pass 2 locks every volume that has no server.lock yet, and every lock
# stays held on its descriptor until this script exits. A start meanwhile opens
# no world: it blocks in core's flock, or fails to open a file created as root.
command -v flock >/dev/null || fail "refused: flock is not installed, so a running instance cannot be detected; run this in the backup image"
for tar_file in "${world_tars[@]}"; do
  name="$(basename "$tar_file" .tar.gz)"
  [ -e "$WORLDS_DIR/$name/server.lock" ] || continue
  exec {fd}<"$WORLDS_DIR/$name/server.lock" || fail "cannot open the server.lock of volume $name"
  flock -xn "$fd" || fail "refused: the server.lock of volume $name is held, so its instance is running; stop it first"
done
for tar_file in "${world_tars[@]}"; do
  name="$(basename "$tar_file" .tar.gz)"
  [ -e "$WORLDS_DIR/$name/server.lock" ] && continue
  mkdir -p "$WORLDS_DIR/$name"
  exec {fd}>>"$WORLDS_DIR/$name/server.lock" || fail "cannot create the server.lock of volume $name"
  flock -xn "$fd" || fail "refused: the server.lock of volume $name is held, so its instance is running; stop it first"
done

echo "restore $BACKUP_SET: rebuilding database $MYSQL_DATABASE at $MYSQL_HOST:$MYSQL_PORT"
# Dropped and recreated rather than loaded on top of whatever is already
# there. A dump made without --add-drop-table cannot overwrite a stale row
# or a table the backup no longer knows about, so a load-in-place restore
# would leave the database in a state the chosen backup never described.
MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
  --user="$MYSQL_USER" -e \
  "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\`"
MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
  --user="$MYSQL_USER" "$MYSQL_DATABASE" < "$BACKUP_SET/mysql.sql"

# The dump holds the fence row raised by the run that took it, and inside that
# lease every commit-first flow would answer capture_fenced.
lower_fence() {
  MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" "$MYSQL_DATABASE" -e \
    "UPDATE capture_fence SET request_id = NULL, raised_until = NULL WHERE id = 1"
}
if [ "$fenced" = 1 ]; then
  lower_fence
fi

for tar_file in "${world_tars[@]}"; do
  name="$(basename "$tar_file" .tar.gz)"
  target="$WORLDS_DIR/$name"
  echo "restore $BACKUP_SET: rebuilding world volume $name at $target"
  mkdir -p "$target"
  # Cleared, not merged onto: anything left in the volume from before the
  # restore (a block broken since the backup, a corrupted region file) must
  # not survive next to the restored files, or the volume ends up in a state
  # the backup set never described either.
  # server.lock stays: replacing it would swap the locked inode for one nothing
  # holds, and the lock taken above would guard nothing.
  find "$target" -mindepth 1 ! -path "$target/server.lock" -delete
  tar -xzf "$tar_file" -C "$target" --anchored --exclude=./server.lock
  # Core opens server.lock for writing as the volume's own user, and this script
  # runs as root. chown keeps the inode, so the lock held above still guards it.
  chown --reference="$target" "$target/server.lock" \
    || fail "cannot give the server.lock of volume $name the owner of $target, so core could not open it; run this as root"
done

echo "restore $BACKUP_SET: complete, database $MYSQL_DATABASE and ${#world_tars[@]} world volume(s) rebuilt"
