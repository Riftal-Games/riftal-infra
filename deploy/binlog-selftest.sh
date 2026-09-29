#!/usr/bin/env bash
# Self-test for binlog-check.sh, against real, throwaway mysql:8 containers.
# Runs on the self-hosted CI runner via `docker`, the same way selftest.sh
# does. One server keeps mysql:8's defaults and must pass. A second is started
# with a one-day retention and must fail naming that setting, which proves the
# check reads the running server rather than agreeing with anything it is shown.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX="$$-$(date +%s)"
NETWORK="riftal_smoke_binlog_net_$SUFFIX"
MYSQL_CONTAINER="riftal_smoke_binlog_mysql_$SUFFIX"

# Per run, so two runs sharing a host, as the self-hosted CI runners do,
# never read each other's output.
LOGS="$(mktemp -d)"

# `docker stop` sends SIGTERM, which mysqld answers with a clean shutdown, and
# --rm removes the container once it exits.
stop_mysql() {
  docker stop -t 60 "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
}
cleanup() {
  stop_mysql
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$LOGS"
}
trap cleanup EXIT

docker network create "$NETWORK" >/dev/null

start_mysql() {
  docker run -d --rm --name "$MYSQL_CONTAINER" --network "$NETWORK" \
    --network-alias mysql -m 1g --cpus 1 \
    -e MYSQL_ROOT_PASSWORD=selftest mysql:8 "$@" >/dev/null
  echo "waiting for mysql to accept connections..."
  for _ in $(seq 1 90); do
    if docker exec "$MYSQL_CONTAINER" mysql -uroot -pselftest -h 127.0.0.1 \
      -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "mysql never became ready" >&2
  exit 1
}

run_check() {
  timeout 60 docker run --rm --network "$NETWORK" \
    -v "$SCRIPT_DIR/binlog-check.sh:/deploy/binlog-check.sh:ro" \
    -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest \
    mysql:8 bash /deploy/binlog-check.sh
}

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=4
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

printf '\n== mysql:8 defaults match the recorded retention\n'
start_mysql
if run_check > "$LOGS/defaults.log" 2>&1; then
  pass "binlog-check.sh exits 0 on mysql:8 defaults"
else
  fail "binlog-check.sh exits nonzero on mysql:8 defaults"
fi
cat "$LOGS/defaults.log"
if grep -q '^binlog-check: PASS$' "$LOGS/defaults.log"; then
  pass "binlog-check.sh prints PASS on mysql:8 defaults"
else
  fail "binlog-check.sh never printed PASS on mysql:8 defaults"
fi
stop_mysql
# The stopped container frees its name only once --rm has removed it.
for _ in $(seq 1 30); do
  docker container inspect "$MYSQL_CONTAINER" >/dev/null 2>&1 || break
  sleep 1
done

printf '\n== a one-day retention is refused\n'
start_mysql --binlog-expire-logs-seconds=86400
if run_check > "$LOGS/short.log" 2>&1; then
  fail "binlog-check.sh exits 0 with a one-day retention"
else
  pass "binlog-check.sh exits nonzero with a one-day retention"
fi
cat "$LOGS/short.log"
if grep -q '^binlog-check: binlog_expire_logs_seconds is 86400, expected 2592000$' \
  "$LOGS/short.log"; then
  pass "binlog-check.sh names binlog_expire_logs_seconds as the mismatch"
else
  fail "binlog-check.sh did not name binlog_expire_logs_seconds as the mismatch"
fi

printf '\n%d passed, %d failed, %d expected\n' "$PASSES" "$FAILURES" "$EXPECTED_ASSERTIONS"
if [ "$FAILURES" -ne 0 ] || [ "$PASSES" -ne "$EXPECTED_ASSERTIONS" ]; then
  exit 1
fi
