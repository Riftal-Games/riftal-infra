#!/usr/bin/env bash
# Self-test for run-migrations.sh, against a real, throwaway mysql:8
# container. Calls `docker` directly, the same way `.github/workflows/ci.yml`'s
# "Lint PHP plugins" step does, so it runs on the self-hosted CI runner and, on
# Nasir's Windows machine, under the WSL fallback engine:
#   wsl -d Ubuntu-26.04 -u runner --exec bash /mnt/c/.../migrations/selftest.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-migrations.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
SUFFIX="$$-$(date +%s)"
CONTAINER="riftal_smoke_migrations_$SUFFIX"
FRESH="riftal_smoke_migrations_fresh_$SUFFIX"
NETWORK="riftal_smoke_migrations_net_$SUFFIX"

# Per run, so two runs sharing a host, as the self-hosted CI runners do,
# never read each other's logs.
LOGS="$(mktemp -d)"

# -v takes the anonymous volume the mysql:8 image declares with each container,
# which would otherwise outlive every run.
cleanup() {
  docker rm -f -v "$CONTAINER" "$FRESH" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$LOGS"
}
trap cleanup EXIT

docker network create "$NETWORK" >/dev/null

start_mysql() {
  docker run -d --rm --name "$1" --network "$NETWORK" --network-alias "$2" \
    -e MYSQL_ROOT_PASSWORD=selftest -e MYSQL_DATABASE=riftal_selftest \
    mysql:8 >/dev/null
}

wait_mysql() {
  echo "waiting for $1 to accept connections..."
  for _ in $(seq 1 60); do
    if docker exec "$1" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "$1 never became ready" >&2
  exit 1
}

start_mysql "$CONTAINER" mysql
wait_mysql "$CONTAINER"
docker exec "$CONTAINER" mysql -uroot -pselftest -e \
  'CREATE DATABASE IF NOT EXISTS riftal_selftest_bad' >/dev/null
docker exec "$CONTAINER" mysql -uroot -pselftest -e \
  'CREATE DATABASE IF NOT EXISTS riftal_selftest_race' >/dev/null
docker exec "$CONTAINER" mysql -uroot -pselftest -e \
  'CREATE DATABASE IF NOT EXISTS riftal_selftest_definer' >/dev/null
docker exec "$CONTAINER" mysql -uroot -pselftest -e \
  'CREATE DATABASE IF NOT EXISTS riftal_selftest_floor' >/dev/null

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=38
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

# Arguments after the first three go to docker run, for provisioning's env.
run_migrations() {
  local dir="$1" db="$2" lock="$3"
  shift 3
  docker run --rm --network "$NETWORK" \
    -v "$RUNNER:/run-migrations.sh:ro" -v "$dir:/migrations:ro" \
    -e MYSQL_HOST="${HOST_ALIAS:-mysql}" -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest \
    -e MYSQL_DATABASE="$db" -e MIGRATIONS_DIR=/migrations \
    -e MIGRATIONS_LOCK_NAME="$lock" "$@" \
    mysql:8 bash /run-migrations.sh
}

query() {
  docker exec "$CONTAINER" mysql -uroot -pselftest -N -B "$1" -e "$2"
}

# Connects as a provisioned login over TCP, so it matches the '%' host part.
as_login() {
  docker exec -e MYSQL_PWD="$3" "${4:-$CONTAINER}" mysql -h 127.0.0.1 -u"$1" -N -B \
    riftal_selftest -e "$2"
}

GRANTS_ARGS=(-v "$FIXTURES/grants:/grants:ro" -e GRANTS_FILE=/grants/grants.sql)
PW_A=selftestPasswordFirst0000001
PW_B=selftestPasswordRotated00002
provision() {
  run_migrations "$FIXTURES/good" riftal_selftest "selftest-prov-$SUFFIX" \
    "${GRANTS_ARGS[@]}" "$@"
}

section "empty migrations directory is a no-op success"
if run_migrations "$FIXTURES/empty" riftal_selftest "selftest-empty-$SUFFIX" \
     >"$LOGS"/out-empty.log 2>&1; then
  pass "empty directory exits 0"
else
  fail "empty directory should exit 0"; cat "$LOGS"/out-empty.log
fi

section "applies pending migrations in order and records them"
if run_migrations "$FIXTURES/good" riftal_selftest "selftest-good-$SUFFIX" \
     >"$LOGS"/out-good.log 2>&1; then
  pass "good fixtures apply cleanly"
else
  fail "good fixtures should apply cleanly"; cat "$LOGS"/out-good.log
fi

count="$(query riftal_selftest 'SELECT COUNT(*) FROM widgets')"
applied_count="$(query riftal_selftest 'SELECT COUNT(*) FROM schema_migrations')"
if [ "$count" = "1" ] && [ "$applied_count" = "2" ]; then
  pass "seeded row present and both migrations recorded"
else
  fail "expected 1 widget row and 2 schema_migrations rows, got $count / $applied_count"
fi

section "second run with nothing new is a no-op success"
if run_migrations "$FIXTURES/good" riftal_selftest "selftest-good2-$SUFFIX" \
     >"$LOGS"/out-good2.log 2>&1 && grep -q 'nothing pending' "$LOGS"/out-good2.log; then
  pass "second run is a no-op and says so"
else
  fail "second run should exit 0 and report a no-op"; cat "$LOGS"/out-good2.log
fi

section "a broken migration halts loudly and is not recorded"
if run_migrations "$FIXTURES/bad" riftal_selftest_bad "selftest-bad-$SUFFIX" \
     >"$LOGS"/out-bad.log 2>&1; then
  fail "a broken migration should exit nonzero"; cat "$LOGS"/out-bad.log
else
  pass "broken migration exits nonzero"
fi

gadget_applied="$(query riftal_selftest_bad \
  "SELECT COUNT(*) FROM schema_migrations WHERE id='0001_create_gadgets.sql'")"
broken_applied="$(query riftal_selftest_bad \
  "SELECT COUNT(*) FROM schema_migrations WHERE id='0002_broken.sql'")"
if [ "$gadget_applied" = "1" ] && [ "$broken_applied" = "0" ]; then
  pass "the file before the break is recorded, the broken one is not"
else
  fail "expected gadgets recorded (1) and broken not recorded (0), got $gadget_applied / $broken_applied"
fi

section "two invocations racing the same lock name do not double-apply"
RACE_LOCK="selftest-race-$SUFFIX"
run_migrations "$FIXTURES/race" riftal_selftest_race "$RACE_LOCK" \
  >"$LOGS"/out-race-a.log 2>&1 &
race_pid_a=$!
run_migrations "$FIXTURES/race" riftal_selftest_race "$RACE_LOCK" \
  >"$LOGS"/out-race-b.log 2>&1 &
race_pid_b=$!

race_rc_a=0
if ! wait "$race_pid_a"; then race_rc_a=$?; fi
race_rc_b=0
if ! wait "$race_pid_b"; then race_rc_b=$?; fi

things_count="$(query riftal_selftest_race 'SELECT COUNT(*) FROM things')"
race_applied="$(query riftal_selftest_race \
  "SELECT COUNT(*) FROM schema_migrations WHERE id='0001_create_things.sql'")"
if [ "$race_rc_a" -eq 0 ] && [ "$race_rc_b" -eq 0 ] \
   && [ "$things_count" = "1" ] && [ "$race_applied" = "1" ]; then
  pass "the lock serialized the race: applied once, both invocations exited 0"
else
  fail "expected both racers to exit 0 and the migration applied exactly once, got exit $race_rc_a/$race_rc_b, things=$things_count, schema_migrations=$race_applied"
  cat "$LOGS"/out-race-a.log
  cat "$LOGS"/out-race-b.log
fi

section "a lock connection that dies early fails cleanly"
# A wrong password ends the lock session before GET_LOCK answers, so bash has
# reaped the coprocess and unset LOCKCONN by the time the exit trap runs.
dead_rc=0
run_migrations "$FIXTURES/good" riftal_selftest "selftest-dead-$SUFFIX" \
  -e MYSQL_PASSWORD=selftestWrongPassword >"$LOGS"/out-deadlock.log 2>&1 || dead_rc=$?
if [ "$dead_rc" -eq 1 ] \
   && grep -q 'lock connection closed before answering GET_LOCK' "$LOGS"/out-deadlock.log \
   && ! grep -q 'unbound variable' "$LOGS"/out-deadlock.log; then
  pass "a dead lock connection exits 1 with its own error and nothing from the trap"
else
  fail "expected exit 1, the GET_LOCK error and no unbound variable, got exit $dead_rc"
  cat "$LOGS"/out-deadlock.log
fi

section "a run whose lock session dies mid-run fails"
lost_rc=0
run_migrations "$FIXTURES/lostlock" riftal_selftest_race selftest-lost-lock \
  >"$LOGS"/out-lostlock.log 2>&1 || lost_rc=$?
if [ "$lost_rc" -eq 1 ] \
   && grep -q "lost the migration lock 'selftest-lost-lock'" "$LOGS"/out-lostlock.log \
   && ! grep -q 'unbound variable' "$LOGS"/out-lostlock.log; then
  pass "a lock lost mid-run exits 1 and says the lock was lost"
else
  fail "expected exit 1 and a lost-lock error, got exit $lost_rc"
  cat "$LOGS"/out-lostlock.log
fi

section "a server below MySQL 8.0.30 is refused before anything is applied"
at_version() {
  run_migrations "$FIXTURES/good" riftal_selftest_floor "selftest-floor-$SUFFIX" \
    -v "$FIXTURES/version-floor:/version-floor:ro" \
    -e BASH_ENV=/version-floor/fake-version.bash -e SELFTEST_MYSQL_VERSION="$1"
}
below_rc=0
at_version 8.0.29-log >"$LOGS"/out-floor-below.log 2>&1 || below_rc=$?
floor_tables="$(query riftal_selftest_floor \
  "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='riftal_selftest_floor'")"
if [ "$below_rc" -eq 1 ] && [ "$floor_tables" = "0" ] \
   && grep -q 'MySQL 8.0.29-log is below the 8.0.30 floor' "$LOGS"/out-floor-below.log; then
  pass "8.0.29 exits 1, names the floor and creates no table"
else
  fail "expected 8.0.29 refused with no table created, got exit $below_rc, tables=$floor_tables"
  cat "$LOGS"/out-floor-below.log
fi
if at_version 8.0.30 >"$LOGS"/out-floor-at.log 2>&1; then
  pass "8.0.30, the floor itself, applies cleanly"
else
  fail "8.0.30 should pass the floor"; cat "$LOGS"/out-floor-at.log
fi
# A comparison that read only the patch number would refuse this one.
if at_version 8.1.0 >"$LOGS"/out-floor-above.log 2>&1; then
  pass "8.1.0 passes the floor"
else
  fail "8.1.0 should pass the floor"; cat "$LOGS"/out-floor-above.log
fi

section "a pending file sorting below the highest applied one is refused"
# Stands in for a database that ran its seeded file before the lower-numbered
# ones landed.
seed_order() {
  docker exec "$CONTAINER" mysql -uroot -pselftest -e "CREATE DATABASE $1" 2>/dev/null
  run_migrations "$FIXTURES/empty" "$1" "selftest-order-$SUFFIX" >/dev/null 2>&1
  query "$1" "INSERT INTO schema_migrations (id) VALUES ('$2')"
}
order_state() {
  query "$1" "SELECT CONCAT(GROUP_CONCAT(TABLE_NAME ORDER BY TABLE_NAME), ' ', (SELECT COUNT(*) FROM schema_migrations)) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$1'"
}
seed_order riftal_selftest_order_low 0002_create_sprockets.sql
low_rc=0
run_migrations "$FIXTURES/order" riftal_selftest_order_low "selftest-order-$SUFFIX" \
  >"$LOGS"/out-order-low.log 2>&1 || low_rc=$?
if [ "$low_rc" -eq 1 ] && grep -q \
     'pending migration(s) 0001_create_cogs.sql sort below 0002_create_sprockets.sql' \
     "$LOGS"/out-order-low.log; then
  pass "a lower pending file exits 1 naming it and the highest applied"
else
  fail "expected exit 1 naming 0001_create_cogs.sql and 0002_create_sprockets.sql, got exit $low_rc"
  cat "$LOGS"/out-order-low.log
fi
low_state="$(order_state riftal_selftest_order_low)"
if [ "$low_state" = "schema_migrations 1" ]; then
  pass "the refusal applied nothing, not even the in-order 0003"
else
  fail "expected only schema_migrations with 1 row, got: $low_state"
fi
seed_order riftal_selftest_order_high 0001_create_cogs.sql
high_rc=0
run_migrations "$FIXTURES/order" riftal_selftest_order_high "selftest-order-$SUFFIX" \
  >"$LOGS"/out-order-high.log 2>&1 || high_rc=$?
high_state="$(order_state riftal_selftest_order_high)"
if [ "$high_rc" -eq 0 ] && [ "$high_state" = "gears,schema_migrations,sprockets 3" ]; then
  pass "pending files all above the highest applied one still apply"
else
  fail "expected exit 0 with sprockets and gears applied, got exit $high_rc, state: $high_state"
  cat "$LOGS"/out-order-high.log
fi

section "provisioning on an existing schema creates the login with its role"
if provision -e RIFTAL_DB_PASSWORD_MINES="$PW_A" >"$LOGS"/out-prov1.log 2>&1; then
  pass "first provisioning run exits 0"
else
  fail "first provisioning run should exit 0"; cat "$LOGS"/out-prov1.log
fi
seen="$(as_login mines 'SELECT CURRENT_ROLE(), COUNT(*) FROM widgets' "$PW_A" 2>&1 || true)"
if [ "$seen" = "$(printf '`riftal_role_mines`@`%%`\t1')" ]; then
  pass "mines logs in with its role active by default and reads widgets"
else
  fail "expected mines with riftal_role_mines to read 1 widget, got: $seen"
fi

section "a second provisioning run is idempotent"
if provision -e RIFTAL_DB_PASSWORD_MINES="$PW_A" >"$LOGS"/out-prov2.log 2>&1 \
   && [ "$(as_login mines 'SELECT 1' "$PW_A" 2>&1)" = "1" ]; then
  pass "second run exits 0 and the same password still logs in"
else
  fail "second run should exit 0 and leave the login usable"; cat "$LOGS"/out-prov2.log
fi

section "a changed password in the environment rotates the login"
provision -e RIFTAL_DB_PASSWORD_MINES="$PW_B" >"$LOGS"/out-prov3.log 2>&1 || true
if [ "$(as_login mines 'SELECT 1' "$PW_B" 2>&1)" = "1" ] \
   && ! as_login mines 'SELECT 1' "$PW_A" >/dev/null 2>&1; then
  pass "the new password logs in and the old one is refused"
else
  fail "rotation should admit only the new password"; cat "$LOGS"/out-prov3.log
fi

section "provisioning refuses bad input loudly and changes nothing"
if provision -e RIFTAL_DB_PASSWORD_MINES="selftestPassword'Quote00001" \
     >"$LOGS"/out-prov-quote.log 2>&1; then
  fail "a password with a quote should be refused"; cat "$LOGS"/out-prov-quote.log
else
  pass "a password with a quote is refused"
fi
if provision -e RIFTAL_DB_PASSWORD_MINES=selftestShort1 >"$LOGS"/out-prov-short.log 2>&1; then
  fail "a password under 24 characters should be refused"; cat "$LOGS"/out-prov-short.log
else
  pass "a password under 24 characters is refused"
fi
ghost_rc=0
provision -e RIFTAL_DB_PASSWORD_GHOST="$PW_A" >"$LOGS"/out-prov-ghost.log 2>&1 || ghost_rc=$?
ghosts="$(query riftal_selftest "SELECT COUNT(*) FROM mysql.user WHERE User='ghost'")"
if [ "$ghost_rc" -ne 0 ] && [ "$ghosts" = "0" ] \
   && grep -q 'riftal_role_ghost does not exist' "$LOGS"/out-prov-ghost.log; then
  pass "a login whose role does not exist is refused and not created"
else
  fail "expected a refusal naming riftal_role_ghost and no ghost user, got exit $ghost_rc, ghosts=$ghosts"
  cat "$LOGS"/out-prov-ghost.log
fi
if [ "$(as_login mines 'SELECT 1' "$PW_B" 2>&1)" = "1" ]; then
  pass "the refused runs left the rotated password in place"
else
  fail "a refused run changed the mines login"
fi

section "a restore onto a fresh server, then the step, rebuilds the login"
start_mysql "$FRESH" fresh
wait_mysql "$FRESH"
docker exec "$CONTAINER" mysqldump -uroot -pselftest --single-transaction --routines \
  --triggers riftal_selftest 2>/dev/null \
  | docker exec -i "$FRESH" mysql -uroot -pselftest riftal_selftest 2>/dev/null
HOST_ALIAS=fresh provision -e RIFTAL_DB_PASSWORD_MINES="$PW_B" >"$LOGS"/out-prov-fresh.log 2>&1 \
  || true
if grep -q 'nothing pending' "$LOGS"/out-prov-fresh.log \
   && [ "$(as_login mines 'SELECT COUNT(*) FROM widgets' "$PW_B" "$FRESH" 2>&1)" = "1" ]; then
  pass "restored schema reapplies nothing, and mines logs in and reads widgets"
else
  fail "the step should rebuild role and login on a restored fresh server"
  cat "$LOGS"/out-prov-fresh.log
fi

section "a DEFINER procedure runs on its definer's privileges and survives a restore"
PW_T=selftestPasswordTally0000005
as_tally() {
  docker exec -e MYSQL_PWD="$PW_T" "${2:-$CONTAINER}" mysql -h 127.0.0.1 -utally -N -B \
    riftal_selftest_definer -e "$1"
}
provision_definer() {
  run_migrations "$FIXTURES/definer" riftal_selftest_definer "selftest-definer-$SUFFIX" \
    -v "$FIXTURES/definer-grants:/grants:ro" -e GRANTS_FILE=/grants/grants.sql \
    -e RIFTAL_DB_PASSWORD_TALLY="$PW_T"
}
definer_rc=0
provision_definer >"$LOGS"/out-prov-definer.log 2>&1 || definer_rc=$?
definer="$(query riftal_selftest_definer "SELECT CONCAT(DEFINER, ' ', SECURITY_TYPE) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='riftal_selftest_definer' AND ROUTINE_NAME='tallies_bump'")"
if [ "$definer_rc" -eq 0 ] && [ "$definer" = "root@% DEFINER" ]; then
  pass "the procedure's definer is the account the runner connected as"
else
  fail "expected exit 0 and definer 'root@% DEFINER', got exit $definer_rc, definer '$definer'"
  cat "$LOGS"/out-prov-definer.log
fi
if [ "$(as_tally 'CALL tallies_bump(); SELECT n FROM tallies' 2>&1)" = "1" ]; then
  pass "a login holding only EXECUTE calls the procedure and the row moves"
else
  fail "tally should call tallies_bump and read n=1"
fi
if as_tally 'UPDATE tallies SET n = 99' >/dev/null 2>&1; then
  fail "tally updated tallies directly, so the call did not prove the definer's privileges"
else
  pass "the same login is refused a direct UPDATE of that table"
fi

docker exec "$CONTAINER" mysqldump -uroot -pselftest --single-transaction --routines \
  --triggers riftal_selftest_definer 2>/dev/null >"$LOGS"/definer-dump.sql
docker exec "$CONTAINER" mysqldump -uroot -pselftest --single-transaction \
  riftal_selftest_definer 2>/dev/null >"$LOGS"/definer-dump-noroutines.sql
if grep -qF 'CREATE DEFINER=`root`@`%` PROCEDURE `tallies_bump`' "$LOGS"/definer-dump.sql \
   && ! grep -q 'PROCEDURE' "$LOGS"/definer-dump-noroutines.sql; then
  pass "a dump carries the procedure and its definer with --routines and not without"
else
  fail "expected the DEFINER clause with --routines and no PROCEDURE without"
fi

docker exec "$FRESH" mysql -uroot -pselftest -e \
  'CREATE DATABASE IF NOT EXISTS riftal_selftest_definer' 2>/dev/null
docker exec -i "$FRESH" mysql -uroot -pselftest riftal_selftest_definer \
  <"$LOGS"/definer-dump.sql 2>/dev/null
HOST_ALIAS=fresh provision_definer >"$LOGS"/out-prov-definer-fresh.log 2>&1 || true
if grep -q 'nothing pending' "$LOGS"/out-prov-definer-fresh.log \
   && [ "$(as_tally 'CALL tallies_bump(); SELECT n FROM tallies' "$FRESH" 2>&1)" = "2" ]; then
  pass "after a restore and the step, the login calls the restored procedure"
else
  fail "the restored procedure should be callable by tally once the step has run"
  cat "$LOGS"/out-prov-definer-fresh.log
fi

# Last use of FRESH: its root@'%' is gone after this.
docker exec "$FRESH" mysql -uroot -pselftest -e \
  "RENAME USER 'root'@'%' TO 'root_renamed'@'%'" 2>/dev/null
orphan="$(as_tally 'CALL tallies_bump()' "$FRESH" 2>&1 || true)"
if [[ "$orphan" == *"ERROR 1449"*"('root'@'%') does not exist"* ]]; then
  pass "a renamed definer makes every call fail with ERROR 1449"
else
  fail "expected ERROR 1449 naming 'root'@'%', got: $orphan"
fi

section "an empty or missing migrations directory still provisions"
PW_C=selftestPasswordEmptyDir0003
PW_D=selftestPasswordNoDir0000004
run_migrations "$FIXTURES/empty" riftal_selftest "selftest-prov-empty-$SUFFIX" \
  "${GRANTS_ARGS[@]}" -e RIFTAL_DB_PASSWORD_MINES="$PW_C" >"$LOGS"/out-prov-empty.log 2>&1 || true
if [ "$(as_login mines 'SELECT COUNT(*) FROM widgets' "$PW_C" 2>&1)" = "1" ]; then
  pass "an empty directory still provisions mines with its role"
else
  fail "an empty directory should still provision mines"; cat "$LOGS"/out-prov-empty.log
fi
run_migrations "$FIXTURES/empty" riftal_selftest "selftest-prov-nodir-$SUFFIX" \
  "${GRANTS_ARGS[@]}" -e MIGRATIONS_DIR=/missing -e RIFTAL_DB_PASSWORD_MINES="$PW_D" \
  >"$LOGS"/out-prov-nodir.log 2>&1 || true
if grep -q 'no migrations directory at /missing' "$LOGS"/out-prov-nodir.log \
   && [ "$(as_login mines 'SELECT COUNT(*) FROM widgets' "$PW_D" 2>&1)" = "1" ]; then
  pass "a missing directory still provisions mines with its role"
else
  fail "a missing directory should still provision mines"; cat "$LOGS"/out-prov-nodir.log
fi

section "a run needing grants fails when the grants file is not a file"
if run_migrations "$FIXTURES/good" riftal_selftest "selftest-nogrants-$SUFFIX" \
     -v "$FIXTURES/empty:/grants.sql:ro" -e GRANTS_FILE=/grants.sql \
     >"$LOGS"/out-prov-nogrants-dir.log 2>&1; then
  fail "a GRANTS_FILE that is a directory should fail the run"; cat "$LOGS"/out-prov-nogrants-dir.log
else
  pass "a GRANTS_FILE that is a directory fails the run"
fi
if run_migrations "$FIXTURES/good" riftal_selftest "selftest-nogrants-$SUFFIX" \
     -e RIFTAL_DB_PASSWORD_MINES="$PW_A" >"$LOGS"/out-prov-nogrants-pw.log 2>&1 \
   || [ "$(as_login mines 'SELECT 1' "$PW_D" 2>&1)" != "1" ]; then
  fail "a login with no grants file should fail and change nothing"; cat "$LOGS"/out-prov-nogrants-pw.log
else
  pass "a login with no grants file fails and leaves the password in place"
fi

section "a plain login named like a role does not pass as the role"
query riftal_selftest \
  "CREATE USER 'riftal_role_decoy'@'%' IDENTIFIED BY 'selftestDecoyPassword0000'"
decoy_rc=0
provision -e RIFTAL_DB_PASSWORD_DECOY="$PW_A" >"$LOGS"/out-prov-decoy.log 2>&1 || decoy_rc=$?
decoys="$(query riftal_selftest "SELECT COUNT(*) FROM mysql.user WHERE User='decoy'")"
if [ "$decoy_rc" -ne 0 ] && [ "$decoys" = "0" ]; then
  pass "a login whose role name belongs to a plain login is refused"
else
  fail "expected decoy refused and not created, got exit $decoy_rc, decoys=$decoys"
  cat "$LOGS"/out-prov-decoy.log
fi

section "each half of the role check refuses on its own"
# Each decoy fails exactly one half of the check, so deleting either half
# admits one of them.
query riftal_selftest \
  "CREATE USER 'riftal_role_lockedpw'@'%' IDENTIFIED BY 'selftestDecoyPassword0000' ACCOUNT LOCK"
query riftal_selftest "CREATE USER 'riftal_role_openblank'@'%'"
for half in LOCKEDPW OPENBLANK; do
  login="${half,,}"
  half_rc=0
  provision -e "RIFTAL_DB_PASSWORD_$half=$PW_A" >"$LOGS/out-prov-half-$login.log" 2>&1 \
    || half_rc=$?
  halves="$(query riftal_selftest "SELECT COUNT(*) FROM mysql.user WHERE User='$login'")"
  if [ "$half_rc" -ne 0 ] && [ "$halves" = "0" ] \
     && grep -q "riftal_role_$login does not exist" "$LOGS/out-prov-half-$login.log"; then
    pass "a login whose role is riftal_role_$login is refused and not created"
  else
    fail "expected $login refused by the role check and not created, got exit $half_rc, users=$halves"
    cat "$LOGS/out-prov-half-$login.log"
  fi
done

section "no provisioning run ever prints a password"
if grep -l -e "$PW_A" -e "$PW_B" -e "$PW_C" -e "$PW_D" -e "$PW_T" -e 'Quote00001' -e selftestShort1 \
     "$LOGS"/out-prov*.log; then
  fail "a password appeared in the log files above"
else
  pass "no password in any provisioning log"
fi

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed: no-op on empty, ordered apply, idempotent re-run, halt-on-error, lock contention, MySQL version floor, login provisioning, DEFINER procedures.\n' "$PASSES"
