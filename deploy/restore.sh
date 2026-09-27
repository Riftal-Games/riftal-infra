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
