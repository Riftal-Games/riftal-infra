#!/usr/bin/env bash
# Verifies a wiped database after the migrations have run on it: every table
# the migrations created is empty, schema_migrations aside.
#
# It counts every base table the schema holds, not a named list, so a table a
# later migration adds is checked without editing this file.
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

sql() {
  MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" -N -B -e "$1"
}

# An empty schema passes every row count, so a check run before the
# migrations would prove nothing.
applied="$(sql "SELECT COUNT(*) FROM \`$MYSQL_DATABASE\`.schema_migrations" 2>/dev/null)" \
  || { echo "wipe-check $MYSQL_DATABASE: FAIL no schema_migrations table; run the migrations first" >&2; exit 1; }
[ "$applied" -gt 0 ] \
  || { echo "wipe-check $MYSQL_DATABASE: FAIL schema_migrations records nothing; run the migrations first" >&2; exit 1; }

mapfile -t tables < <(sql "SELECT TABLE_NAME FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = '$MYSQL_DATABASE' AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME <> 'schema_migrations' ORDER BY TABLE_NAME")

dirty=0
for table in "${tables[@]}"; do
  rows="$(sql "SELECT COUNT(*) FROM \`$MYSQL_DATABASE\`.\`$table\`")"
  if [ "$rows" != "0" ]; then
    echo "wipe-check $MYSQL_DATABASE: FAIL $table holds $rows row(s)" >&2
    dirty=1
  fi
done
[ "$dirty" -eq 0 ] || exit 1

echo "wipe-check $MYSQL_DATABASE: ok, $applied migration(s) applied, ${#tables[@]} table(s) all empty"
