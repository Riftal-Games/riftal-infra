#!/usr/bin/env bash
# Self-test for run-migrations.sh, against a real, throwaway mysql:8
# container. Runs on the self-hosted CI runner via `docker`, the same way
# `.github/workflows/ci.yml`'s "Lint PHP plugins" step already does; not
# runnable on Nasir's Windows machine, which has no docker, only wslc. See
# the "docker form" section of /dev-stack for the same split.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-migrations.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
SUFFIX="$$-$(date +%s)"
CONTAINER="riftal_smoke_migrations_$SUFFIX"
FRESH="riftal_smoke_migrations_fresh_$SUFFIX"
NETWORK="riftal_smoke_migrations_net_$SUFFIX"

# -v takes the anonymous volume the mysql:8 image declares with each container,
# which would otherwise outlive every run.
cleanup() {
  docker rm -f -v "$CONTAINER" "$FRESH" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$NETWORK" >/dev/null

start_mysql() {
  docker run -d --name "$1" --network "$NETWORK" --network-alias "$2" \
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

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=17
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
     >/tmp/out-empty.log 2>&1; then
  pass "empty directory exits 0"
else
  fail "empty directory should exit 0"; cat /tmp/out-empty.log
fi

section "applies pending migrations in order and records them"
if run_migrations "$FIXTURES/good" riftal_selftest "selftest-good-$SUFFIX" \
     >/tmp/out-good.log 2>&1; then
  pass "good fixtures apply cleanly"
else
  fail "good fixtures should apply cleanly"; cat /tmp/out-good.log
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
     >/tmp/out-good2.log 2>&1 && grep -q 'nothing pending' /tmp/out-good2.log; then
  pass "second run is a no-op and says so"
else
  fail "second run should exit 0 and report a no-op"; cat /tmp/out-good2.log
fi

section "a broken migration halts loudly and is not recorded"
if run_migrations "$FIXTURES/bad" riftal_selftest_bad "selftest-bad-$SUFFIX" \
     >/tmp/out-bad.log 2>&1; then
  fail "a broken migration should exit nonzero"; cat /tmp/out-bad.log
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
  >/tmp/out-race-a.log 2>&1 &
race_pid_a=$!
run_migrations "$FIXTURES/race" riftal_selftest_race "$RACE_LOCK" \
  >/tmp/out-race-b.log 2>&1 &
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
  cat /tmp/out-race-a.log
  cat /tmp/out-race-b.log
fi

section "provisioning on an existing schema creates the login with its role"
if provision -e RIFTAL_DB_PASSWORD_MINES="$PW_A" >/tmp/out-prov1.log 2>&1; then
  pass "first provisioning run exits 0"
else
  fail "first provisioning run should exit 0"; cat /tmp/out-prov1.log
fi
seen="$(as_login mines 'SELECT CURRENT_ROLE(), COUNT(*) FROM widgets' "$PW_A" 2>&1 || true)"
if [ "$seen" = "$(printf '`riftal_role_mines`@`%%`\t1')" ]; then
  pass "mines logs in with its role active by default and reads widgets"
else
  fail "expected mines with riftal_role_mines to read 1 widget, got: $seen"
fi

section "a second provisioning run is idempotent"
if provision -e RIFTAL_DB_PASSWORD_MINES="$PW_A" >/tmp/out-prov2.log 2>&1 \
   && [ "$(as_login mines 'SELECT 1' "$PW_A" 2>&1)" = "1" ]; then
  pass "second run exits 0 and the same password still logs in"
else
  fail "second run should exit 0 and leave the login usable"; cat /tmp/out-prov2.log
fi

section "a changed password in the environment rotates the login"
provision -e RIFTAL_DB_PASSWORD_MINES="$PW_B" >/tmp/out-prov3.log 2>&1 || true
if [ "$(as_login mines 'SELECT 1' "$PW_B" 2>&1)" = "1" ] \
   && ! as_login mines 'SELECT 1' "$PW_A" >/dev/null 2>&1; then
  pass "the new password logs in and the old one is refused"
else
  fail "rotation should admit only the new password"; cat /tmp/out-prov3.log
fi

section "provisioning refuses bad input loudly and changes nothing"
if provision -e RIFTAL_DB_PASSWORD_MINES="selftestPassword'Quote00001" \
     >/tmp/out-prov-quote.log 2>&1; then
  fail "a password with a quote should be refused"; cat /tmp/out-prov-quote.log
else
  pass "a password with a quote is refused"
fi
if provision -e RIFTAL_DB_PASSWORD_MINES=selftestShort1 >/tmp/out-prov-short.log 2>&1; then
  fail "a password under 24 characters should be refused"; cat /tmp/out-prov-short.log
else
  pass "a password under 24 characters is refused"
fi
ghost_rc=0
provision -e RIFTAL_DB_PASSWORD_GHOST="$PW_A" >/tmp/out-prov-ghost.log 2>&1 || ghost_rc=$?
ghosts="$(query riftal_selftest "SELECT COUNT(*) FROM mysql.user WHERE User='ghost'")"
if [ "$ghost_rc" -ne 0 ] && [ "$ghosts" = "0" ] \
   && grep -q 'riftal_role_ghost does not exist' /tmp/out-prov-ghost.log; then
  pass "a login whose role does not exist is refused and not created"
else
  fail "expected a refusal naming riftal_role_ghost and no ghost user, got exit $ghost_rc, ghosts=$ghosts"
  cat /tmp/out-prov-ghost.log
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
HOST_ALIAS=fresh provision -e RIFTAL_DB_PASSWORD_MINES="$PW_B" >/tmp/out-prov-fresh.log 2>&1 \
  || true
if grep -q 'nothing pending' /tmp/out-prov-fresh.log \
   && [ "$(as_login mines 'SELECT COUNT(*) FROM widgets' "$PW_B" "$FRESH" 2>&1)" = "1" ]; then
  pass "restored schema reapplies nothing, and mines logs in and reads widgets"
else
  fail "the step should rebuild role and login on a restored fresh server"
  cat /tmp/out-prov-fresh.log
fi

section "no provisioning run ever prints a password"
if grep -l -e "$PW_A" -e "$PW_B" -e 'Quote00001' -e selftestShort1 /tmp/out-prov*.log; then
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
printf 'all %s assertions passed: no-op on empty, ordered apply, idempotent re-run, halt-on-error, lock contention, login provisioning.\n' "$PASSES"
