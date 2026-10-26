#!/usr/bin/env bash
# Confirms a running MySQL keeps the binary log this repo's backup and restore
# work assumes (README.md, Binary log retention): on, row format, full row
# images, 30 days before automatic purge. ADR 005 in the riftal-pm workspace
# names the binlog as the only per-change history of a balance, so a server
# that quietly keeps less is a lost audit trail, found only when it is needed.
#
# The values are mysql:8's own defaults. Nothing sets them, which is why this
# check exists: `mysql:8` is a floating tag, and a new release that moves a
# default would move ours with it and say nothing.
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:?MYSQL_HOST is required}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"

# 30 days. It must outlast the oldest backup set any restore can pick, so the
# binlog still reaches back past it.
EXPECTED_EXPIRE_SECONDS=2592000

row="$(MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
  --user="$MYSQL_USER" -N -B -e \
  'SELECT @@version, @@log_bin, @@binlog_format, @@binlog_row_image,
          @@binlog_expire_logs_seconds, @@binlog_expire_logs_auto_purge')"

IFS=$'\t' read -r version log_bin format row_image expire_seconds auto_purge <<< "$row"

echo "binlog-check: version=$version log_bin=$log_bin binlog_format=$format" \
  "binlog_row_image=$row_image binlog_expire_logs_seconds=$expire_seconds" \
  "binlog_expire_logs_auto_purge=$auto_purge"

mismatches=0
expect() {
  local name="$1" actual="$2" wanted="$3"
  if [ "$actual" != "$wanted" ]; then
    echo "binlog-check: $name is $actual, expected $wanted" >&2
    mismatches=$((mismatches + 1))
  fi
}

expect log_bin "$log_bin" 1
expect binlog_format "$format" ROW
expect binlog_row_image "$row_image" FULL
expect binlog_expire_logs_seconds "$expire_seconds" "$EXPECTED_EXPIRE_SECONDS"
expect binlog_expire_logs_auto_purge "$auto_purge" 1

if [ "$mismatches" -ne 0 ]; then
  echo "binlog-check: FAIL, $mismatches setting(s) differ from the recorded retention" >&2
  exit 1
fi
echo "binlog-check: PASS"
