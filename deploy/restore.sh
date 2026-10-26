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

for tar_file in "${world_tars[@]}"; do
  name="$(basename "$tar_file" .tar.gz)"
  target="$WORLDS_DIR/$name"
  echo "restore $BACKUP_SET: rebuilding world volume $name at $target"
  mkdir -p "$target"
  # Cleared, not merged onto: anything left in the volume from before the
  # restore (a block broken since the backup, a corrupted region file) must
  # not survive next to the restored files, or the volume ends up in a state
  # the backup set never described either.
  find "$target" -mindepth 1 -delete
  tar -xzf "$tar_file" -C "$target"
done

echo "restore $BACKUP_SET: complete, database $MYSQL_DATABASE and ${#world_tars[@]} world volume(s) rebuilt"
