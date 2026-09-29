#!/usr/bin/env bash
# Self-test for wipe.sh and wipe-check.sh, against one throwaway mysql:8
# container that publishes nothing. Runs under `docker` on the CI runner and
# under the Docker in the WSL distro that hosts it, as restore-selftest.sh.
#
# The fixture database holds economy_balance_snapshot with ADR 006's DDL, rows
# in it and in the tables it copies, and a table no migration creates. A wipe
# that emptied a named list of tables would leave the snapshot or the stray
# table behind and fail here. Each refusal in wipe.sh is driven, and must leave
# the fixture unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DB=riftal_smoke_wipe
C="riftal_smoke_wipe_$$_$(date +%s)"
LOGS="$(mktemp -d)"

# A second server with performance_schema off, where performance_schema's
# processlist is empty even for the connection reading it.
C_PSOFF="${C}_psoff"

cleanup() {
  docker stop -t 30 "$C" "$C_PSOFF" >/dev/null 2>&1 || true
  rm -rf "$LOGS"
}
trap cleanup EXIT

start() {
  local name="$1"
  shift
  docker run -d --rm --name "$name" -m 1g --cpus 1 \
    -v "$REPO_DIR/deploy:/deploy:ro" -v "$REPO_DIR/migrations:/migrations-runner:ro" \
    -e MYSQL_ROOT_PASSWORD=selftest -e MYSQL_DATABASE="$DB" mysql:8 "$@" >/dev/null
}
wait_ready() {
  for _ in $(seq 1 90); do
    docker exec "$1" mysql -uroot -pselftest -h 127.0.0.1 -e 'SELECT 1' >/dev/null 2>&1 && return
    sleep 1
  done
  echo "mysql in $1 never became ready" >&2
  exit 1
}
start "$C"
start "$C_PSOFF" --performance-schema=OFF
wait_ready "$C"
wait_ready "$C_PSOFF"

q() { docker exec "$C" mysql -uroot -pselftest -N -B -e "$1" 2>/dev/null; }
sh_in() { docker exec "$C" bash -c "$1"; }
env_run() {
  docker exec -e MYSQL_HOST=127.0.0.1 -e MYSQL_PASSWORD=selftest "$@"
}

docker exec -i "$C" bash -c 'mkdir -p /tmp/migrations && cat > /tmp/migrations/0001_fixture.sql' <<'SQL'
CREATE TABLE balances (
  account_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
  balance_minor_units BIGINT UNSIGNED NOT NULL DEFAULT 0
);
CREATE TABLE economy_ledger (
  request_id CHAR(36) CHARACTER SET ascii NOT NULL PRIMARY KEY,
  account_id BIGINT UNSIGNED NOT NULL
);
CREATE TABLE economy_balance_snapshot (
  entry_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  account_id BIGINT UNSIGNED NULL,
  balance_minor_units BIGINT UNSIGNED NULL,
  request_id CHAR(36) CHARACTER SET ascii NULL,
  UNIQUE KEY economy_balance_snapshot_account_uq (account_id),
  UNIQUE KEY economy_balance_snapshot_request_uq (request_id),
  CONSTRAINT economy_balance_snapshot_entry_chk CHECK (
    (account_id IS NOT NULL AND balance_minor_units IS NOT NULL AND request_id IS NULL)
    OR (account_id IS NULL AND balance_minor_units IS NULL AND request_id IS NOT NULL)
  )
);
SQL

migrate() {
  env_run -e MYSQL_DATABASE="$DB" -e MIGRATIONS_DIR=/tmp/migrations \
    "$C" bash /migrations-runner/run-migrations.sh
}
wipe() {
  env_run -e MYSQL_USER="${WIPE_USER:-root}" -e MYSQL_DATABASE="$1" -e WIPE_CONFIRM="$2" -e BACKUP_SET="$3" "$C" bash /deploy/wipe.sh
}
check() {
  env_run -e MYSQL_DATABASE="$DB" "$C" bash /deploy/wipe-check.sh
}
snapshot_rows() { q "SELECT COUNT(*) FROM $DB.economy_balance_snapshot"; }

migrate >"$LOGS/migrate-1.log" 2>&1 || { cat "$LOGS/migrate-1.log"; exit 1; }
q "INSERT INTO $DB.balances VALUES (1, 500);
   INSERT INTO $DB.economy_ledger VALUES ('00000000-0000-7000-8000-000000000001', 1);
   INSERT INTO $DB.economy_balance_snapshot (account_id, balance_minor_units, request_id)
     VALUES (1, 500, NULL), (NULL, NULL, '00000000-0000-7000-8000-000000000001');
   CREATE TABLE $DB.stray_unmigrated (id INT PRIMARY KEY);
   INSERT INTO $DB.stray_unmigrated VALUES (1);"

sh_in "mkdir -p /tmp/set /tmp/other /tmp/empty /tmp/absent \
  && printf 'x\n' > /tmp/absent/mysql.sql && printf 'mysql_database: riftal_smoke_absent\n' > /tmp/absent/manifest.txt \
  && MYSQL_PWD=selftest mysqldump -uroot --single-transaction --routines $DB > /tmp/set/mysql.sql \
  && printf 'mysql_database: $DB\n' > /tmp/set/manifest.txt \
  && cp /tmp/set/mysql.sql /tmp/other/ && printf 'mysql_database: riftal_other\n' > /tmp/other/manifest.txt"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=19
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
refused() {
  local name="$1" reason="$2" log="$LOGS/$1.log"
  shift 2
  if "$@" >"$log" 2>&1; then
    fail "$name: should be refused"; cat "$log"
  elif grep -q "refused: .*$reason" "$log"; then
    pass "$name: refused, $reason"
  else
    fail "$name: not refused for '$reason'"; cat "$log"
  fi
}

printf '\n== wipe-check fails on a live database and names the snapshot table\n'
if check >"$LOGS/check-live.log" 2>&1; then
  fail "wipe-check passed on a database holding rows"
elif grep -q 'economy_balance_snapshot holds 2 row' "$LOGS/check-live.log"; then
  pass "wipe-check fails naming economy_balance_snapshot"
else
  fail "wipe-check failed without naming economy_balance_snapshot"; cat "$LOGS/check-live.log"
fi

printf '\n== wipe refuses anything but an explicitly named, backed-up, idle target\n'
refused bad-name "must match" wipe riftal-smoke riftal-smoke /tmp/set
refused no-confirm "WIPE_CONFIRM must equal" wipe "$DB" "" /tmp/set
refused wrong-confirm "WIPE_CONFIRM must equal" wipe "$DB" riftal_other /tmp/set
refused no-dump "no non-empty" wipe "$DB" "$DB" /tmp/empty
refused other-db-backup "does not name database" wipe "$DB" "$DB" /tmp/other
refused absent-database "no database riftal_smoke_absent" \
  wipe riftal_smoke_absent riftal_smoke_absent /tmp/absent

sleeping() { q "SELECT COUNT(*) FROM performance_schema.processlist WHERE INFO LIKE 'SELECT SLEEP%'"; }
hold() {
  docker exec -d "$C" mysql -uroot -pselftest "$@" -e 'SELECT SLEEP(8)'
  for _ in $(seq 1 20); do [ "$(sleeping)" != "0" ] && return; sleep 0.5; done
}
released() { for _ in $(seq 1 30); do [ "$(sleeping)" = "0" ] && return; sleep 0.5; done; }

# An account with every privilege on the schema but no PROCESS sees only its
# own threads in the processlist, so it would count 0 with a session connected.
q "CREATE USER 'wiper'@'%' IDENTIFIED BY 'selftest'; GRANT ALL ON $DB.* TO 'wiper'@'%'"
hold "$DB"
refused connected-session "other session" wipe "$DB" "$DB" /tmp/set
WIPE_USER=wiper refused no-process "lacks a direct PROCESS grant" wipe "$DB" "$DB" /tmp/set
released
hold
refused no-default-db-session "other session" wipe "$DB" "$DB" /tmp/set
released

[ "$(snapshot_rows)" = "2" ] && pass "every refusal left the snapshot rows in place" \
  || fail "a refused wipe changed the database"

printf '\n== a confirmed wipe, then the migrations, leaves every table empty\n'
if wipe "$DB" "$DB" /tmp/set >"$LOGS/wipe.log" 2>&1; then
  pass "the confirmed wipe exits 0"
else
  fail "the confirmed wipe should exit 0"; cat "$LOGS/wipe.log"
fi
if check >"$LOGS/check-premigrate.log" 2>&1; then
  fail "wipe-check passed before the migrations ran"
else
  pass "wipe-check fails before the migrations ran"
fi
migrate >"$LOGS/migrate-2.log" 2>&1 && pass "the migrations reapply after the wipe" \
  || { fail "the migrations should reapply after the wipe"; cat "$LOGS/migrate-2.log"; }
if check >"$LOGS/check-wiped.log" 2>&1; then
  pass "wipe-check passes on the wiped, migrated database"
else
  fail "wipe-check should pass after the wipe"; cat "$LOGS/check-wiped.log"
fi
[ "$(snapshot_rows)" = "0" ] && pass "economy_balance_snapshot exists and is empty" \
  || fail "economy_balance_snapshot should exist and be empty, got '$(snapshot_rows)'"
[ "$(q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$DB' AND TABLE_NAME = 'stray_unmigrated'")" = "0" ] \
  && pass "a table no migration creates is gone" || fail "stray_unmigrated survived the wipe"

printf '\n== with performance_schema off, a connected session still refuses the wipe\n'
qp() { docker exec "$C_PSOFF" mysql -uroot -pselftest -N -B -e "$1" 2>/dev/null; }
qp "CREATE TABLE $DB.t (id INT PRIMARY KEY); INSERT INTO $DB.t VALUES (1), (2), (3)"
docker exec "$C_PSOFF" bash -c "mkdir -p /tmp/set && printf 'x\n' > /tmp/set/mysql.sql \
  && printf 'mysql_database: $DB\n' > /tmp/set/manifest.txt"
docker exec -d "$C_PSOFF" mysql -uroot -pselftest "$DB" -e 'SELECT SLEEP(20)'
held=0
for _ in $(seq 1 20); do
  [ "$(qp "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE 'SELECT SLEEP%'")" = "1" ] \
    && { held=1; break; }
  sleep 0.5
done
[ "$held" -eq 1 ] || { echo "the session on $C_PSOFF never connected" >&2; exit 1; }
refused psoff-session "processlist does not show this session" \
  env_run -e MYSQL_DATABASE="$DB" -e WIPE_CONFIRM="$DB" -e BACKUP_SET=/tmp/set "$C_PSOFF" bash /deploy/wipe.sh
[ "$(qp "SELECT COUNT(*) FROM $DB.t")" = "3" ] && pass "the refused wipe left the rows in place" \
  || fail "the wipe with performance_schema off changed the database"

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed\n' "$PASSES"
