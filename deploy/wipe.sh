#!/usr/bin/env bash
# Drops and recreates the shared database for a wipe between MVPs. It is the
# database step only: instances are stopped and a backup is taken before it.
#
# The schema is dropped whole rather than truncated table by table, so no list
# of tables can fall behind the migrations. A list would miss a derived table
# with no foreign keys, such as economy_balance_snapshot, and ADR 006 reads a
# non-empty snapshot table as a valid snapshot.
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:?MYSQL_HOST is required}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
MYSQL_DATABASE="${MYSQL_DATABASE:?MYSQL_DATABASE is required}"
WIPE_CONFIRM="${WIPE_CONFIRM:-}"
BACKUP_SET="${BACKUP_SET:?BACKUP_SET is required: the backup.sh set taken of this database just before the wipe}"

fail() {
  echo "wipe $MYSQL_DATABASE: refused: $1" >&2
  exit 1
}

# Keeps quoting out of the SQL below, and matches every name the stacks use.
[[ "$MYSQL_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || fail "the database name must match [A-Za-z0-9_]+"

# The target is typed twice, so a wipe never follows from a default or from a
# MYSQL_DATABASE left exported by an earlier command.
[ "$WIPE_CONFIRM" = "$MYSQL_DATABASE" ] || fail "WIPE_CONFIRM must equal MYSQL_DATABASE exactly"

[ -s "$BACKUP_SET/mysql.sql" ] || fail "no non-empty $BACKUP_SET/mysql.sql"
grep -qx "mysql_database: $MYSQL_DATABASE" "$BACKUP_SET/manifest.txt" 2>/dev/null \
  || fail "$BACKUP_SET/manifest.txt does not name database $MYSQL_DATABASE"

sql() {
  MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" -N -B -e "$1"
}

[ "$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$MYSQL_DATABASE'")" = "1" ] \
  || fail "no database $MYSQL_DATABASE on $MYSQL_HOST:$MYSQL_PORT"

# A connected instance would keep writing through the wipe, into tables the
# drop is about to remove or the migrations are about to recreate. This reads
# the moment of the check only: stopping every instance first is the operator's
# step, and this catches one that was missed.
#
# Without PROCESS the processlist shows only this account's own threads, so the
# count below would read 0 whatever is connected. PROCESS held through a role
# is not seen here, which refuses rather than guesses.
[ "$(sql "SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE PRIVILEGE_TYPE = 'PROCESS'
  AND GRANTEE = CONCAT('''', REPLACE(CURRENT_USER(), '@', '''@'''), '''')")" = "1" ] \
  || fail "$MYSQL_USER lacks a direct PROCESS grant, so it cannot see every session"
# The processlist is empty when the server runs with performance_schema off,
# and could be blind for a reason not foreseen here, so its count is trusted
# only once it shows this connection's own thread.
#
# A session with no default database can still write here by qualified name.
counts="$(sql "SELECT COALESCE(SUM(ID = CONNECTION_ID()), 0), COALESCE(SUM((DB = '$MYSQL_DATABASE' OR DB IS NULL)
  AND COMMAND <> 'Daemon' AND ID <> CONNECTION_ID()), 0) FROM performance_schema.processlist")"
read -r own sessions <<<"$counts"
[ "$own" = "1" ] || fail "the processlist does not show this session, so it cannot see the others; is performance_schema off?"
[ "$sessions" = "0" ] || fail "$sessions other session(s) are connected to $MYSQL_DATABASE or to no database; stop every instance first"

echo "wipe $MYSQL_DATABASE: dropping and recreating at $MYSQL_HOST:$MYSQL_PORT, backup set $BACKUP_SET"
sql "DROP DATABASE \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\`"
echo "wipe $MYSQL_DATABASE: complete, empty; run ../migrations/run-migrations.sh, then wipe-check.sh"
