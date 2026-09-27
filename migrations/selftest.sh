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
CONTAINER="riftal-migrations-selftest-$SUFFIX"
NETWORK="riftal-migrations-selftest-net-$SUFFIX"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$NETWORK" >/dev/null

docker run -d --name "$CONTAINER" --network "$NETWORK" --network-alias mysql \
  -e MYSQL_ROOT_PASSWORD=selftest -e MYSQL_DATABASE=riftal_selftest \
  mysql:8 >/dev/null

echo "waiting for mysql to accept connections..."
ready=0
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "mysql never became ready" >&2
  exit 1
fi
docker exec "$CONTAINER" mysql -uroot -pselftest -e \
  'CREATE DATABASE IF NOT EXISTS riftal_selftest_bad' >/dev/null

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=6
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

run_migrations() {
  local dir="$1" db="$2" lock="$3"
  docker run --rm --network "$NETWORK" \
    -v "$RUNNER:/run-migrations.sh:ro" -v "$dir:/migrations:ro" \
    -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest \
    -e MYSQL_DATABASE="$db" -e MIGRATIONS_DIR=/migrations \
    -e MIGRATIONS_LOCK_NAME="$lock" \
    mysql:8 bash /run-migrations.sh
}

query() {
  docker exec "$CONTAINER" mysql -uroot -pselftest -N -B "$1" -e "$2"
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
printf 'all %s assertions passed: no-op on empty, ordered apply, idempotent re-run, halt-on-error.\n' "$PASSES"
