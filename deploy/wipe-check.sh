#!/usr/bin/env bash
# Verifies a wipe after the migrations have run and before any instance starts:
# every instance volume holds no level and no file in players/ or plugin_data/,
# and every table the migrations created is empty, schema_migrations aside.
#
# It counts every base table the schema holds, not a named list, so a table a
# later migration adds is checked without editing this file.
#
# The files the wipe keeps (riftal-infra#1123), and anything else on a volume,
# are not read: a kept file is not a wipe left undone.
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:?MYSQL_HOST is required}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
MYSQL_DATABASE="${MYSQL_DATABASE:?MYSQL_DATABASE is required}"

[[ "$MYSQL_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || {
  echo "wipe-check: the database name must match [A-Za-z0-9_]+" >&2
  exit 1
}

dirty=0
flag() {
  echo "wipe-check $MYSQL_DATABASE: FAIL $1" >&2
  dirty=1
}
stop() {
  flag "$1"
  exit 1
}

[ -n "${WORLDS_DIR:-}" ] || stop "WORLDS_DIR is required: the directory every instance volume is mounted under, as for wipe.sh"
[ -n "${LEVEL_LOCKS_DIR:-}" ] && [ -d "$LEVEL_LOCKS_DIR" ] \
  || stop "LEVEL_LOCKS_DIR must name a directory: designer/levels, as for wipe.sh"

# Volumes are found the way backup.sh and wipe-volumes.sh find them.
shopt -s nullglob
volumes=("$WORLDS_DIR"/*/)
[ "${#volumes[@]}" -gt 0 ] || stop "no instance volumes found under $WORLDS_DIR"

shopt -s dotglob
for volume in "${volumes[@]}"; do
  name="$(basename "$volume")"
  clean=1
  for level in "$volume"worlds/*/; do
    zone="$(basename "$level")"
    clean=0
    if [ -e "$LEVEL_LOCKS_DIR/$zone.lock.json" ]; then
      flag "level $zone on $name has an ADR 009 build, and checking it against its lock's content_sha256 is riftal-infra#1126"
    else
      # riftal-pm#1312: the wipe clears such a level and leaves it absent, and
      # only a boot, after this check, can write one again.
      flag "level $zone on $name has no ADR 009 build and should be absent after a wipe"
    fi
  done
  for dir in players plugin_data; do
    [ -d "$volume$dir" ] || continue
    files="$(find "$volume$dir" -mindepth 1 ! -type d | wc -l)"
    if [ "$files" -ne 0 ]; then
      clean=0
      flag "$dir/ on $name holds $files file(s)"
    fi
  done
  [ "$clean" -eq 0 ] \
    || echo "wipe-check $MYSQL_DATABASE: volume $name: ok, no level, and players/ and plugin_data/ hold no file"
done
shopt -u nullglob dotglob

sql() {
  MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" -N -B -e "$1"
}

# An empty schema passes every row count, so a check run before the
# migrations would prove nothing.
applied="$(sql "SELECT COUNT(*) FROM \`$MYSQL_DATABASE\`.schema_migrations" 2>/dev/null)" \
  || stop "no schema_migrations table; run the migrations first"
[ "$applied" -gt 0 ] || stop "schema_migrations records nothing; run the migrations first"

mapfile -t tables < <(sql "SELECT TABLE_NAME FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = '$MYSQL_DATABASE' AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME <> 'schema_migrations' ORDER BY TABLE_NAME")

for table in "${tables[@]}"; do
  rows="$(sql "SELECT COUNT(*) FROM \`$MYSQL_DATABASE\`.\`$table\`")"
  [ "$rows" = "0" ] || flag "$table holds $rows row(s)"
done
[ "$dirty" -eq 0 ] || exit 1

echo "wipe-check $MYSQL_DATABASE: ok, $applied migration(s) applied, ${#tables[@]} table(s) all empty"
