#!/usr/bin/env bash
# Self-test for binlog-check.sh, against real, throwaway mysql:8 containers.
# Runs on the self-hosted CI runner via `docker`, the same way selftest.sh
# does. One server keeps mysql:8's defaults and must pass. Every setting the
# check reads then gets its own negative control: that one setting is set
# wrong, and the check must fail naming it and nothing else. That proves the
# check reads the running server rather than agreeing with anything it is
# shown, and that no two settings are read through each other's column.
#
# Four of the settings are dynamic, so their controls run against the same
# server with SET GLOBAL, each put back before the next. log_bin is not, so its
# control needs a second server started with --skip-log-bin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX="$$-$(date +%s)"
NETWORK="riftal_smoke_binlog_net_$SUFFIX"
MYSQL_CONTAINER="riftal_smoke_binlog_mysql_$SUFFIX"
CHECK_CONTAINER="riftal_smoke_binlog_check_$SUFFIX"

# Per run, so two runs sharing a host, as the self-hosted CI runners do,
# never read each other's output.
LOGS="$(mktemp -d)"

# `docker stop` sends SIGTERM, which mysqld answers with a clean shutdown, and
# --rm removes the container once it exits.
stop_mysql() {
  docker stop -t 60 "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
}
cleanup() {
  docker rm -f -v "$CHECK_CONTAINER" >/dev/null 2>&1 || true
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
    if docker exec -e MYSQL_PWD=selftest "$MYSQL_CONTAINER" mysql -uroot -h 127.0.0.1 \
      -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "mysql never became ready" >&2
  exit 1
}

set_global() {
  docker exec -e MYSQL_PWD=selftest "$MYSQL_CONTAINER" mysql -uroot -h 127.0.0.1 \
    -e "SET GLOBAL $1"
}

# The docker client forwards timeout's SIGTERM to the check's bash, which as
# PID 1 ignores it, so only the SIGKILL from -k ends the client, and that
# leaves the container running. Removing it by name is what frees the runner.
run_check() {
  local rc=0
  timeout -k 5 60 docker run --rm --name "$CHECK_CONTAINER" --network "$NETWORK" \
    -m 1g --cpus 1 \
    -v "$SCRIPT_DIR/binlog-check.sh:/deploy/binlog-check.sh:ro" \
    -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest \
    mysql:8 bash /deploy/binlog-check.sh || rc=$?
  docker rm -f -v "$CHECK_CONTAINER" >/dev/null 2>&1 || true
  return "$rc"
}

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=14
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

expect_pass() {
  local log="$LOGS/$1.log" what="$2"
  if run_check > "$log" 2>&1; then
    pass "binlog-check.sh exits 0 $what"
  else
    fail "binlog-check.sh exits nonzero $what"
  fi
  cat "$log"
  if grep -q '^binlog-check: PASS$' "$log"; then
    pass "binlog-check.sh prints PASS $what"
  else
    fail "binlog-check.sh never printed PASS $what"
  fi
}

# One wrong setting must give a nonzero exit, that setting's mismatch line, and
# a count of exactly one, so a check that reads one column for another fails.
expect_refused() {
  local log="$LOGS/$1.log" name="$1" actual="$2" wanted="$3"
  if run_check > "$log" 2>&1; then
    fail "binlog-check.sh exits 0 with $name=$actual"
  else
    pass "binlog-check.sh exits nonzero with $name=$actual"
  fi
  cat "$log"
  if grep -qx "binlog-check: $name is $actual, expected $wanted" "$log" &&
    [ "$(grep -c '^binlog-check: .* is .*, expected ' "$log")" -eq 1 ] &&
    grep -qx 'binlog-check: FAIL, 1 setting(s) differ from the recorded retention' "$log"; then
    pass "binlog-check.sh names $name, and only $name, as the mismatch"
  else
    fail "binlog-check.sh did not name $name, and only $name, as the mismatch"
  fi
}

printf '\n== mysql:8 defaults match the recorded retention\n'
start_mysql
expect_pass defaults "on mysql:8 defaults"

printf '\n== binlog_format STATEMENT is refused\n'
set_global "binlog_format = 'STATEMENT'"
expect_refused binlog_format STATEMENT ROW
set_global "binlog_format = 'ROW'"

printf '\n== binlog_row_image MINIMAL is refused\n'
set_global "binlog_row_image = 'MINIMAL'"
expect_refused binlog_row_image MINIMAL FULL
set_global "binlog_row_image = 'FULL'"

printf '\n== a one-day retention is refused\n'
set_global "binlog_expire_logs_seconds = 86400"
expect_refused binlog_expire_logs_seconds 86400 2592000
set_global "binlog_expire_logs_seconds = 2592000"

printf '\n== automatic purge off is refused\n'
set_global "binlog_expire_logs_auto_purge = OFF"
expect_refused binlog_expire_logs_auto_purge 0 1
set_global "binlog_expire_logs_auto_purge = ON"

printf '\n== every setting put back passes again\n'
expect_pass restored "with every setting put back"

stop_mysql
# The stopped container frees its name only once --rm has removed it.
freed=0
for _ in $(seq 1 30); do
  if ! docker container inspect "$MYSQL_CONTAINER" >/dev/null 2>&1; then
    freed=1
    break
  fi
  sleep 1
done
if [ "$freed" -ne 1 ]; then
  echo "$MYSQL_CONTAINER still exists 30 s after its stop, so the --skip-log-bin server cannot take its name" >&2
  exit 1
fi

printf '\n== the binary log off is refused\n'
start_mysql --skip-log-bin
expect_refused log_bin 0 1

printf '\n%d passed, %d failed, %d expected\n' "$PASSES" "$FAILURES" "$EXPECTED_ASSERTIONS"
if [ "$FAILURES" -ne 0 ] || [ "$PASSES" -ne "$EXPECTED_ASSERTIONS" ]; then
  exit 1
fi
