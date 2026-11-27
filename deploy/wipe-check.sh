#!/usr/bin/env bash
# Verifies a wipe after the migrations have run and before any instance starts:
# every instance volume holds no level but a re-seeded ADR 009 build and no file
# in players/ or plugin_data/, and every table the migrations created is empty,
# schema_migrations aside and capture_fence holding only the row its migration
# seeds.
#
# It counts every base table the schema holds, not a named list, so a table a
# later migration adds is checked without editing this file.
#
# A level with an ADR 009 build is the one level a volume may hold, and only as
# the build re-seeded (riftal-infra#1126): its level-manifest.json carries the
# lock's content_sha256 and its file tree hashes to the manifest's tree_sha256.
#
# The files the wipe keeps (riftal-infra#1123), and anything else on a volume,
# are not read: a kept file is not a wipe left undone.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/wipe-lib.sh"

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
  seeded=
  for level in "$volume"worlds/*/; do
    zone="$(basename "$level")"
    lock="$LEVEL_LOCKS_DIR/$zone.lock.json"
    manifest="${level}level-manifest.json"
    if [ ! -e "$lock" ]; then
      # riftal-pm#1312: the wipe clears such a level and leaves it absent, and
      # only a boot, after this check, can write one again.
      clean=0
      flag "level $zone on $name has no ADR 009 build and should be absent after a wipe"
      continue
    fi
    want="$(json_digest "$lock" content_sha256)"
    if [ -z "$want" ]; then
      problem="has an ADR 009 build, and $lock holds no single content_sha256"
    elif [ "$(json_digest "$manifest" content_sha256)" != "$want" ]; then
      problem="does not carry content_sha256 $want, the one in $lock"
    elif [ "$(tree_sha256 "$level")" != "$(json_digest "$manifest" tree_sha256)" ]; then
      problem="has a file tree that is not the one its level-manifest.json names"
    else
      seeded="$seeded $zone"
      continue
    fi
    clean=0
    flag "level $zone on $name $problem"
  done
  for dir in players plugin_data; do
    [ -d "$volume$dir" ] || continue
    files="$(find "$volume$dir" -mindepth 1 ! -type d | wc -l)"
    if [ "$files" -ne 0 ]; then
      clean=0
      flag "$dir/ on $name holds $files file(s)"
    fi
  done
  if [ "$clean" -eq 1 ]; then
    held="no level"
    [ -z "$seeded" ] || held="level(s)$seeded match their lock's content_sha256"
    echo "wipe-check $MYSQL_DATABASE: volume $name: ok, $held, and players/ and plugin_data/ hold no file"
  fi
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

# A process substitution's exit status escapes set -e, so the list is read
# into a variable first. A list that reads as nothing checks no table, and a
# schema with migrations applied always holds one, so that fails too: it is an
# account that cannot see the tables, not a schema that has none.
listed="$(sql "SELECT TABLE_NAME FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = '$MYSQL_DATABASE' AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME <> 'schema_migrations' ORDER BY TABLE_NAME")" \
  || stop "could not list the tables in $MYSQL_DATABASE"
[ -n "$listed" ] \
  || stop "information_schema lists no table but schema_migrations, though $applied migration(s) applied; MYSQL_USER $MYSQL_USER cannot see the tables to check them"
mapfile -t tables <<<"$listed"

seeded=0
for table in "${tables[@]}"; do
  rows="$(sql "SELECT COUNT(*) FROM \`$MYSQL_DATABASE\`.\`$table\`")"
  if [ "$table" = capture_fence ]; then
    # riftal-game's migration 0027 seeds this one row, lowered, and nothing
    # deletes it (riftal-pm ADR 027), so a freshly migrated schema holds it.
    # Raised, it is a capture run since the migrations.
    lowered="$(sql "SELECT COUNT(*) FROM \`$MYSQL_DATABASE\`.capture_fence
      WHERE id = 1 AND request_id IS NULL AND raised_until IS NULL")"
    if [ "$rows" = "1" ] && [ "$lowered" = "1" ]; then
      seeded=1
    else
      flag "capture_fence should hold only migration 0027's row, id 1 and lowered; it holds $rows row(s), $lowered of them that row"
    fi
  elif [ "$rows" != "0" ]; then
    flag "$table holds $rows row(s)"
  fi
done
[ "$dirty" -eq 0 ] || exit 1

echo "wipe-check $MYSQL_DATABASE: ok, $applied migration(s) applied, ${#tables[@]} table(s) empty but for $seeded seeded row(s)"
