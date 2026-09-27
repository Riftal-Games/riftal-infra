#!/usr/bin/env bash
# Applies pending migrations from MIGRATIONS_DIR under a MySQL named lock.
#
# The lock exists because more than one instance container can boot at once
# against the shared database (CLAUDE.md hard rule 5: one shared database
# across instances), and GET_LOCK()/RELEASE_LOCK() is MySQL's own mechanism
# for that. Applied migrations are tracked in schema_migrations so a run with
# nothing pending is a no-op success, never a re-application.
#
# GET_LOCK/RELEASE_LOCK are scoped to the connection that acquired the lock,
# so that connection has to stay open for the whole run. It is held by a
# coprocess and used for nothing else: the lock only blocks other callers of
# GET_LOCK on the same name, never ordinary queries, so the actual migration
# work below runs over its own throwaway connections.
set -euo pipefail

LOCK_NAME="${MIGRATIONS_LOCK_NAME:-riftal_schema_migrations}"
LOCK_TIMEOUT="${MIGRATIONS_LOCK_TIMEOUT:-60}"

MYSQL_HOST="${MYSQL_HOST:?MYSQL_HOST is required}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
MYSQL_DATABASE="${MYSQL_DATABASE:?MYSQL_DATABASE is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# riftal-game owns the migration files; this repo only runs them. The
# fallback assumes the sibling checkout every other runbook here assumes.
# Real invocations pass MIGRATIONS_DIR explicitly, pointing at whatever this
# environment actually mounted.
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$SCRIPT_DIR/../../riftal-game/lib/resources/sql/migrations}"

run_sql() {
  MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" --database="$MYSQL_DATABASE" -N -B "$@"
}

# No table to migrate until riftal-game ships one (riftal-infra#7). A
# nonexistent or empty directory is nothing pending, not a fault.
if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "no migrations directory at $MIGRATIONS_DIR, nothing to apply"
  exit 0
fi

shopt -s nullglob
files=("$MIGRATIONS_DIR"/*.sql)
shopt -u nullglob
if [ "${#files[@]}" -eq 0 ]; then
  echo "no migration files in $MIGRATIONS_DIR, nothing to apply"
  exit 0
fi
mapfile -t files < <(printf '%s\n' "${files[@]}" | sort)

coproc LOCKCONN {
  # mysql fully buffers stdout once it is a pipe rather than a tty, so the
  # GET_LOCK result below never reaches us until the buffer fills. stdbuf
  # forces line buffering so the coprocess actually behaves like a session
  # and not a script that only flushes at exit.
  MYSQL_PWD="$MYSQL_PASSWORD" exec stdbuf -oL mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" --database="$MYSQL_DATABASE" -N -B
}
lock_pid="$LOCKCONN_PID"

released=0
release_lock() {
  if [ "$released" -eq 0 ]; then
    released=1
    if kill -0 "$lock_pid" 2>/dev/null; then
      printf "SELECT RELEASE_LOCK('%s');\n" "$LOCK_NAME" >&"${LOCKCONN[1]}" 2>/dev/null || true
    fi
  fi
  # Closing the write side is what lets the held mysql session see EOF and
  # exit; without it "wait" below blocks forever, success or failure alike.
  eval "exec ${LOCKCONN[1]}>&-" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
}
trap release_lock EXIT

printf "SELECT GET_LOCK('%s', %s);\n" "$LOCK_NAME" "$LOCK_TIMEOUT" >&"${LOCKCONN[1]}"
if ! IFS= read -r lock_result <&"${LOCKCONN[0]}"; then
  echo "lock connection closed before answering GET_LOCK('$LOCK_NAME')" >&2
  exit 1
fi
if [ "$lock_result" != "1" ]; then
  echo "could not acquire lock '$LOCK_NAME' within ${LOCK_TIMEOUT}s (GET_LOCK returned: $lock_result)" >&2
  exit 1
fi
echo "acquired lock '$LOCK_NAME'"

run_sql <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
  id VARCHAR(255) NOT NULL PRIMARY KEY,
  applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
SQL

applied_output="$(run_sql -e 'SELECT id FROM schema_migrations')"
applied=()
if [ -n "$applied_output" ]; then
  mapfile -t applied <<< "$applied_output"
fi

is_applied() {
  local id="$1" a
  for a in "${applied[@]+"${applied[@]}"}"; do
    [ "$a" = "$id" ] && return 0
  done
  return 1
}

pending=0
for f in "${files[@]}"; do
  id="$(basename "$f")"
  if is_applied "$id"; then
    continue
  fi
  pending=$((pending + 1))
  echo "applying $id"
  if ! run_sql < "$f"; then
    echo "migration $id failed, stopping" >&2
    exit 1
  fi
  escaped_id="${id//\'/\'\'}"
  if ! run_sql -e "INSERT INTO schema_migrations (id) VALUES ('$escaped_id')"; then
    echo "$id applied but could not be recorded as applied, stopping" >&2
    exit 1
  fi
done

if [ "$pending" -eq 0 ]; then
  echo "nothing pending, ${#files[@]} migration(s) already applied"
else
  echo "applied $pending pending migration(s)"
fi
