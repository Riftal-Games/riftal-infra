#!/usr/bin/env bash
# Applies pending migrations from MIGRATIONS_DIR under a MySQL named lock,
# then, under the same lock, provisions the per-plugin logins of ADR 008
# (riftal-pm docs/decisions/008-per-plugin-mysql-users.md, item 4).
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

# Filename order decides the apply order and the out-of-order refusal below,
# and a collating locale such as en_US.UTF-8 puts 0001_a before 0001_B where
# C puts it after. Pinned here, the order is bytewise on every image.
export LC_ALL=C

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
grants_explicit="${GRANTS_FILE+set}"
GRANTS_FILE="${GRANTS_FILE:-$SCRIPT_DIR/../../riftal-game/lib/resources/sql/grants.sql}"

# Every RIFTAL_DB_PASSWORD_<NAME> is a login to provision. The charset rule
# keeps SQL quoting out of the question, so a password is interpolated as is.
# All of them are checked before anything connects, so a bad environment
# changes nothing.
logins=()
while IFS= read -r var; do
  name="${var#RIFTAL_DB_PASSWORD_}"
  if [[ ! "$name" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    echo "$var: the login name must match [A-Z][A-Z0-9_]*" >&2
    exit 1
  fi
  pw="${!var}"
  if [[ "$pw" =~ [^A-Za-z0-9] ]]; then
    echo "$var: the password contains a character outside [A-Za-z0-9]" >&2
    exit 1
  fi
  if [ "${#pw}" -lt 24 ]; then
    echo "$var: the password is shorter than 24 characters" >&2
    exit 1
  fi
  logins+=("${name,,}")
done < <(compgen -e | grep '^RIFTAL_DB_PASSWORD_' || true)

# A run that names a grants file or provisions a login depends on the grants
# reaching the roles, and a bind mount of a missing host path arrives as an
# empty directory rather than as nothing. Only a run asking for neither may
# go without, which keeps the sibling-checkout default optional.
if { [ -n "$grants_explicit" ] || [ "${#logins[@]}" -gt 0 ]; } \
   && { [ ! -f "$GRANTS_FILE" ] || [ ! -r "$GRANTS_FILE" ]; }; then
  echo "grants file $GRANTS_FILE is not a readable regular file, and GRANTS_FILE or a RIFTAL_DB_PASSWORD_* is set" >&2
  exit 1
fi

run_sql() {
  MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" --database="$MYSQL_DATABASE" -N -B "$@"
}

# A nonexistent or empty directory is nothing pending, not a fault, and the
# run still goes on to provision logins.
files=()
if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "no migrations directory at $MIGRATIONS_DIR, nothing to apply"
else
  shopt -s nullglob
  files=("$MIGRATIONS_DIR"/*.sql)
  shopt -u nullglob
fi
if [ "${#files[@]}" -gt 0 ]; then
  mapfile -t files < <(printf '%s\n' "${files[@]}" | sort)
fi

coproc LOCKCONN {
  # mysql fully buffers stdout once it is a pipe rather than a tty, so the
  # GET_LOCK result below never reaches us until the buffer fills. stdbuf
  # forces line buffering so the coprocess actually behaves like a session
  # and not a script that only flushes at exit.
  MYSQL_PWD="$MYSQL_PASSWORD" exec stdbuf -oL mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" --database="$MYSQL_DATABASE" -N -B
}
lock_pid="$LOCKCONN_PID"

lock_held=0
release_lock() {
  local rc=$? release_result=""
  # Once bash reaps a dead coprocess it unsets LOCKCONN and closes both of its
  # descriptors, so an empty value means the lock session is already over.
  local lock_fd="${LOCKCONN[1]-}" lock_out="${LOCKCONN[0]-}"
  # A coprocess that has exited but is not yet reaped still has its pipe, and
  # writing to a pipe with no reader raises SIGPIPE, which would end this
  # trap before the close and wait below. Ignored, the write just fails.
  trap '' PIPE
  if [ -n "$lock_fd" ]; then
    # Only a 1 proves the lock was still held by this session. A session
    # killed mid-run answers with an error, or, if the client reconnected,
    # with NULL from a fresh session that never held it.
    if printf "SELECT RELEASE_LOCK('%s');\n" "$LOCK_NAME" >&"$lock_fd" 2>/dev/null; then
      IFS= read -r -t 30 release_result <&"$lock_out" 2>/dev/null || true
    fi
    # Closing the write side is what lets the held mysql session see EOF and
    # exit; without it "wait" below blocks forever, success or failure alike.
    eval "exec $lock_fd>&-" 2>/dev/null || true
  fi
  wait "$lock_pid" 2>/dev/null || true
  # MySQL drops a named lock when its session ends, so a session that ended
  # before the run did left a window where another runner could take the lock
  # and apply the same files concurrently. That run cannot count as a success.
  if [ "$lock_held" -eq 1 ] && [ "$release_result" != "1" ]; then
    echo "lost the migration lock '$LOCK_NAME' before the run finished, so another runner may have migrated concurrently" >&2
    if [ "$rc" -eq 0 ]; then
      exit 1
    fi
  fi
}
trap release_lock EXIT

printf "SELECT GET_LOCK('%s', %s);\n" "$LOCK_NAME" "$LOCK_TIMEOUT" >&"${LOCKCONN[1]}"
if ! IFS= read -r lock_result <&"${LOCKCONN[0]}"; then
  echo "lock connection closed before answering GET_LOCK('$LOCK_NAME')" >&2
  exit 1
fi
if [ "$lock_result" != "1" ]; then
  # Only a 0 is a timeout. GET_LOCK answers NULL on an error, such as its
  # statement being killed with KILL QUERY.
  if [ "$lock_result" = "0" ]; then
    failure="could not acquire lock '$LOCK_NAME' within ${LOCK_TIMEOUT}s (GET_LOCK returned: 0)"
  else
    failure="could not acquire lock '$LOCK_NAME': GET_LOCK returned $lock_result, which is an error and not a timeout"
  fi
  # Any login may take the lock by name, so the holder is not necessarily a
  # runner. Each read below is a separate moment, so the holder may have let
  # go in between. performance_schema.processlist needs no grant, but without
  # PROCESS it shows a login only its own sessions, and with
  # performance_schema=OFF it is empty for every login. An empty row cannot
  # tell those apart from a session that has ended, so none is claimed.
  holder="unknown, IS_USED_LOCK could not be read"
  holder_id="$(run_sql -e "SELECT IS_USED_LOCK('$LOCK_NAME')" 2>/dev/null)" || holder_id=""
  if [ "$holder_id" = "NULL" ]; then
    holder="no session by the time IS_USED_LOCK was read"
  elif [[ "$holder_id" =~ ^[0-9]+$ ]]; then
    if holder_row="$(run_sql -e "SELECT USER, HOST FROM performance_schema.processlist WHERE ID = $holder_id" 2>/dev/null)"; then
      if [[ "$holder_row" == *$'\t'* ]]; then
        holder="connection $holder_id, user ${holder_row%%$'\t'*} from host ${holder_row#*$'\t'}"
      else
        holder="connection $holder_id, whose user and host could not be read: its processlist row came back empty"
      fi
    else
      holder="connection $holder_id, whose user and host could not be read: the performance_schema.processlist query failed"
    fi
  fi
  echo "$failure, held by $holder" >&2
  exit 1
fi
lock_held=1
echo "acquired lock '$LOCK_NAME'"

# grants.sql may use REVOKE IF EXISTS, which needs MySQL 8.0.30 (ADR 008), and
# the mysql:8 tag floats, so the server's own answer decides, before anything
# is written.
server_version="$(run_sql -e 'SELECT VERSION()')"
if [[ ! "$server_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  echo "could not read a MySQL version from VERSION(), which answered '$server_version'" >&2
  exit 1
fi
if [ $((10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]})) -lt 8000030 ]; then
  echo "MySQL $server_version is below the 8.0.30 floor of ADR 008, so nothing was applied" >&2
  exit 1
fi

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

# A pending file that sorts below one already applied would run after it here
# but before it on a fresh database, so the two could end with different
# schemas. The applied list was read under the lock, so no other runner can
# move the highest applied file while this is decided. Both sides go through
# the same LC_ALL=C sort as the file list.
highest=""
if [ "${#applied[@]}" -gt 0 ]; then
  highest="$(printf '%s\n' "${applied[@]}" | sort | tail -n 1)"
fi
out_of_order=()
for f in "${files[@]+"${files[@]}"}"; do
  id="$(basename "$f")"
  if [ -n "$highest" ] && ! is_applied "$id" \
     && [ "$(printf '%s\n' "$id" "$highest" | sort | head -n 1)" = "$id" ]; then
    out_of_order+=("$id")
  fi
done
if [ "${#out_of_order[@]}" -gt 0 ]; then
  echo "pending migration(s) ${out_of_order[*]} sort below $highest, the highest already applied, so nothing was applied" >&2
  exit 1
fi

# Grants are applied on every run rather than recorded, because a dump
# restored onto a fresh server carries schema_migrations but no roles.
apply_grants() {
  if [ -f "$GRANTS_FILE" ]; then
    echo "applying grants from $GRANTS_FILE"
    if ! run_sql "$@" < "$GRANTS_FILE"; then
      echo "grants file $GRANTS_FILE failed, stopping" >&2
      exit 1
    fi
  else
    echo "no grants file at $GRANTS_FILE, no grants applied"
  fi
}

# Dropping a procedure to recreate it drops every role's EXECUTE on it, so a
# run that stops partway still owes grants to the files it applied. --force
# carries on past grants naming what the failed file never created.
stop_after_grants() {
  echo "$1, applying grants for what did apply, then stopping" >&2
  apply_grants --force
  exit 1
}

pending=0
for f in "${files[@]+"${files[@]}"}"; do
  id="$(basename "$f")"
  if is_applied "$id"; then
    continue
  fi
  pending=$((pending + 1))
  echo "applying $id"
  if ! run_sql < "$f"; then
    stop_after_grants "migration $id failed"
  fi
  escaped_id="${id//\'/\'\'}"
  if ! run_sql -e "INSERT INTO schema_migrations (id) VALUES ('$escaped_id')"; then
    stop_after_grants "$id applied but could not be recorded as applied"
  fi
done

if [ "$pending" -eq 0 ]; then
  echo "nothing pending, ${#files[@]} migration(s) already applied"
else
  echo "applied $pending pending migration(s)"
fi

apply_grants

for login in "${logins[@]+"${logins[@]}"}"; do
  role="riftal_role_$login"
  # CREATE ROLE makes a locked account with no password, which is what tells
  # a role apart from a login that merely carries the role's name.
  if [ "$(run_sql -e "SELECT COUNT(*) FROM mysql.user WHERE User='$role' AND Host='%' AND account_locked='Y' AND authentication_string=''")" != "1" ]; then
    echo "role $role does not exist, so no login was provisioned; grants.sql must create it" >&2
    exit 1
  fi
done

# CREATE alone would keep an existing login's old password, so ALTER follows
# and the environment always decides it. printf is a builtin, so a password
# reaches mysql on stdin and never on a command line.
for login in "${logins[@]+"${logins[@]}"}"; do
  pw_var="RIFTAL_DB_PASSWORD_${login^^}"
  role="riftal_role_$login"
  if ! printf '%s\n' \
      "CREATE USER IF NOT EXISTS '$login'@'%' IDENTIFIED BY '${!pw_var}';" \
      "ALTER USER '$login'@'%' IDENTIFIED BY '${!pw_var}';" \
      "GRANT $role TO '$login'@'%';" \
      "SET DEFAULT ROLE ALL TO '$login'@'%';" | run_sql; then
    echo "provisioning login $login failed, stopping" >&2
    exit 1
  fi
  echo "provisioned login $login with role $role"
done
