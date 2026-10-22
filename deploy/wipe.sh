#!/usr/bin/env bash
# Drops and recreates the shared database for a wipe between MVPs, after
# wipe-volumes.sh has cleared every instance volume. Instances are stopped and
# a backup is taken before it. The whole procedure, with its rollback, is
# deploy/WIPE.md.
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
# The set is taken with every instance already stopped, so nothing it lacks can
# be written before the wipe. A set older than this was most likely taken while
# instances still ran, and restoring it would lose their later writes.
WIPE_BACKUP_MAX_AGE_MINUTES="${WIPE_BACKUP_MAX_AGE_MINUTES:-60}"

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

# deploy/WIPE.md names this set as the rollback, so it must pass the checks
# restore.sh makes before it touches anything, or a wipe could go ahead with no
# way back.
[ -d "$BACKUP_SET/worlds" ] || fail "$BACKUP_SET has no worlds/ directory, so restore.sh could not roll the wipe back"
shopt -s nullglob
world_tars=("$BACKUP_SET"/worlds/*.tar.gz)
shopt -u nullglob
[ "${#world_tars[@]}" -gt 0 ] || fail "$BACKUP_SET/worlds holds no .tar.gz, so restore.sh could not roll the wipe back"
for tar_file in "${world_tars[@]}"; do
  tar -tzf "$tar_file" >/dev/null || fail "$tar_file does not list with tar -tzf, so restore.sh could not roll the wipe back"
done

[[ "$WIPE_BACKUP_MAX_AGE_MINUTES" =~ ^[1-9][0-9]{0,5}$ ]] \
  || fail "WIPE_BACKUP_MAX_AGE_MINUTES must be a whole number of minutes from 1 to 999999"
# backup.sh writes the line once, as date -u +%Y%m%dT%H%M%S%NZ. Anything else
# leaves the set's age unknown, which refuses rather than guesses.
stamps="$(grep -c '^timestamp: ' "$BACKUP_SET/manifest.txt" || true)"
[ "$stamps" = "1" ] || fail "$BACKUP_SET/manifest.txt holds $stamps timestamp line(s), not exactly one"
stamp="$(sed -n 's/^timestamp: //p' "$BACKUP_SET/manifest.txt")"
[[ "$stamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})[0-9]{9}Z$ ]] \
  || fail "$BACKUP_SET/manifest.txt timestamp '$stamp' is not in backup.sh's format"
m=("${BASH_REMATCH[@]}")
taken="$(date -u -d "${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}" +%s 2>/dev/null)" \
  || fail "$BACKUP_SET/manifest.txt timestamp '$stamp' is not a valid UTC time"
age=$(( $(date -u +%s) - taken ))
# The stamp is the clock of the host backup.sh ran on. On this host, a set from
# the future means the clock moved or the manifest was not written by backup.sh.
# From another host, it is that clock running ahead of this one, and the set
# stays refused because its age cannot be known.
[ "$age" -ge 0 ] \
  || fail "$BACKUP_SET was taken $(( -age ))s in the future by this host's clock; if backup.sh ran on another host, its clock is ahead of this one"
[ "$age" -le $(( WIPE_BACKUP_MAX_AGE_MINUTES * 60 )) ] \
  || fail "$BACKUP_SET is $(( age / 60 )) minute(s) old, over WIPE_BACKUP_MAX_AGE_MINUTES=$WIPE_BACKUP_MAX_AGE_MINUTES; take a fresh backup with every instance stopped"

sql() {
  MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" -N -B -e "$1"
}

[ "$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$MYSQL_DATABASE'")" = "1" ] \
  || fail "no database $MYSQL_DATABASE on $MYSQL_HOST:$MYSQL_PORT"

# The one dev predicate (riftal-pm#1314): two keys with no default, the second
# read only once the check above has found that database on the server.
if [ -z "${RIFTAL_DEV_ENV+set}" ]; then
  dev="RIFTAL_DEV_ENV is unset"
elif [ -z "$RIFTAL_DEV_ENV" ]; then
  dev="RIFTAL_DEV_ENV is empty"
elif [ "$RIFTAL_DEV_ENV" != 1 ]; then
  dev="RIFTAL_DEV_ENV is '$RIFTAL_DEV_ENV', not 1"
elif [ "$MYSQL_DATABASE" != riftal_dev ]; then
  dev="RIFTAL_DEV_ENV is 1 against database $MYSQL_DATABASE, not riftal_dev"
else
  dev=dev
fi

# A connected instance would keep writing through the wipe, into tables the
# drop is about to remove or the migrations are about to recreate. This reads
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
  || fail "$MYSQL_USER lacks PROCESS, directly or through an active role, so it cannot see every session"
read -r _ own sessions < <(grep '^counts' <<<"$probe") || true
[ "$own" = "1" ] || fail "the processlist does not show this session, so it cannot see the others; is performance_schema off?"
[ "$sessions" = "0" ] || fail "$sessions other session(s) are connected to $MYSQL_HOST:$MYSQL_PORT; close every other connection, instances first"

source "$(dirname "${BASH_SOURCE[0]}")/wipe-volumes.sh"
wipe_volumes "$dev"

echo "wipe $MYSQL_DATABASE: dropping and recreating at $MYSQL_HOST:$MYSQL_PORT, backup set $BACKUP_SET"
sql "DROP DATABASE \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\`"
echo "wipe $MYSQL_DATABASE: complete, empty; run ../migrations/run-migrations.sh, then wipe-check.sh"
