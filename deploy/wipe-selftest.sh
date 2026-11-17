#!/usr/bin/env bash
# Self-test for wipe.sh and wipe-check.sh, against two throwaway mysql:8
# containers that publish nothing: one as the fixture, and one started with
# performance_schema off to drive the refusal that needs it. Runs under
# `docker` on the CI runner and under the Docker in the WSL distro that hosts
# it, as restore-selftest.sh does.
#
# The fixture database holds economy_balance_snapshot with ADR 006's DDL, rows
# in it and in the tables it copies, and a table no migration creates. A wipe
# that emptied a named list of tables would leave the snapshot or the stray
# table behind and fail here. Each refusal in wipe.sh is driven, and must leave
# the fixture unchanged. The two for a missing PROCESS run after the confirmed
# wipe, since their accounts cannot see the session a refusal case holds.
#
# The fixture also holds capture_fence with the row migration 0027 seeds.
# wipe-check must pass with that row lowered and fail with it raised or gone.
#
# The confirmed wipe must write nothing to stderr, and its stdout must be
# exactly wipe-volumes.sh's line for the one volume, holding no level, and its
# own two progress lines, naming the default port deploy/README.md's
# MYSQL_PORT row documents, so a failure set -e lets through, or a default
# that drifts from the README, fails here though the wipe exits 0.
# wipe-volumes-selftest.sh covers the volumes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DB=riftal_smoke_wipe
C="riftal_smoke_wipe_$$_$(date +%s)"
LOGS="$(mktemp -d)"

# MYSQL_PORT stays unset in every script's environment, so each one reaches
# the server only through the default deploy/README.md documents, and the wipe
# prints that default back.
DOCUMENTED_DEFAULT_PORT="$(sed -n 's/^| `MYSQL_PORT` | [^|]* | `\([^`]*\)` |.*$/\1/p' "$SCRIPT_DIR/README.md")"
case "$DOCUMENTED_DEFAULT_PORT" in
  '' | *[!0-9]*)
    echo "deploy/README.md holds no single MYSQL_PORT row with a numeric default to read; it read '$DOCUMENTED_DEFAULT_PORT'" >&2
    rm -rf "$LOGS"
    exit 1
    ;;
esac

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
MYSQL_HOST=127.0.0.1
env_run() {
  docker exec -e MYSQL_HOST="$MYSQL_HOST" -e MYSQL_PASSWORD=selftest "$@"
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
# riftal-game's migration 0027 seeds capture_fence's one row, so a migrated
# schema is never all empty. riftal-game is a separate private repo this CI
# does not check out, so deploy/fence-fixture.sql carries a copy of the table,
# the seed and the control procedures backup.sh calls.
docker exec "$C" cp /deploy/fence-fixture.sql /tmp/migrations/0002_capture_fence.sql

migrate() {
  env_run -e MYSQL_DATABASE="$DB" -e MIGRATIONS_DIR=/tmp/migrations \
    "$C" bash /migrations-runner/run-migrations.sh
}
wipe() {
  env_run -e MYSQL_USER="${WIPE_USER:-root}" ${WIPE_MAX_AGE:+-e "WIPE_BACKUP_MAX_AGE_MINUTES=$WIPE_MAX_AGE"} \
    ${WIPE_TZ:+-e "TZ=$WIPE_TZ"} -e WORLDS_DIR=/tmp/worlds -e LEVEL_LOCKS_DIR=/tmp/locks \
    -e MYSQL_DATABASE="$1" -e WIPE_CONFIRM="$2" -e BACKUP_SET="$3" "$C" bash /deploy/wipe.sh
}
check() {
  env_run -e MYSQL_DATABASE="$DB" -e WORLDS_DIR=/tmp/worlds -e LEVEL_LOCKS_DIR=/tmp/locks \
    "$@" "$C" bash /deploy/wipe-check.sh
}
snapshot_rows() { q "SELECT COUNT(*) FROM $DB.economy_balance_snapshot"; }

migrate >"$LOGS/migrate-1.log" 2>&1 || { cat "$LOGS/migrate-1.log"; exit 1; }
q "INSERT INTO $DB.balances VALUES (1, 500);
   INSERT INTO $DB.economy_ledger VALUES ('00000000-0000-7000-8000-000000000001', 1);
   INSERT INTO $DB.economy_balance_snapshot (account_id, balance_minor_units, request_id)
     VALUES (1, 500, NULL), (NULL, NULL, '00000000-0000-7000-8000-000000000001');
   CREATE TABLE $DB.stray_unmigrated (id INT PRIMARY KEY);
   INSERT INTO $DB.stray_unmigrated VALUES (1);"

# A zone the container cannot parse would read as UTC and prove nothing, in
# backup.sh's run below or in the age cases.
for zone in RIFT-14:+1400 RIFT+12:-1200; do
  [ "$(docker exec -e TZ="${zone%%:*}" "$C" date +%z)" = "${zone#*:}" ] \
    || { echo "TZ=${zone%%:*} does not read as ${zone#*:} in $C" >&2; exit 1; }
done
# The fresh set is backup.sh's own, so a timestamp format other than
# backup.sh's fails the confirmed wipe below as well as every real wipe.
# It runs 14 hours east of UTC, so a stamp taken in local time reads as a set
# from the future and fails that wipe too.
sh_in "mkdir -p /tmp/locks /tmp/worlds/riftal_smoke_vol && printf 'x\n' > /tmp/worlds/riftal_smoke_vol/level.dat"
env_run -e TZ=RIFT-14 -e MYSQL_USER=root -e MYSQL_DATABASE="$DB" -e BACKUP_ROOT=/tmp/backups -e WORLDS_DIR=/tmp/worlds \
  "$C" bash /deploy/backup.sh >"$LOGS/backup.log" 2>&1 || { cat "$LOGS/backup.log"; exit 1; }
sh_in 'sets=(/tmp/backups/[0-9]*); [ "${#sets[@]}" = 1 ] && cp -r "${sets[0]}" /tmp/set'
# backup.sh's own date format, read from its one ts= line, so the stale and
# future sets below follow it wherever it goes. Its zone flag is left behind:
# these stamps are always taken in UTC, and the fresh set above is what tests
# backup.sh's zone.
STAMP_FORMAT="$(sed -n 's/^ts="\$(date [^+]*+\([^ )]*\))"$/\1/p' "$SCRIPT_DIR/backup.sh")"
if [ -z "$STAMP_FORMAT" ] || [ "$(printf '%s\n' "$STAMP_FORMAT" | wc -l)" -ne 1 ]; then
  echo "backup.sh holds no single ts=\"\$(date ... +FORMAT)\" line to read its stamp format from" >&2
  exit 1
fi
# Prints a manifest's timestamp line as backup.sh writes it, for a set taken
# at the given date -d time.
stamp_cmd() { echo "date -u -d '$1' +'timestamp: $STAMP_FORMAT'"; }
NOW="grep '^timestamp: ' /tmp/set/manifest.txt"
# A set restore.sh accepts holds worlds/ with at least one tar that lists.
TAR=riftal_smoke_vol.tar.gz
sh_in "mkdir -p /tmp/other /tmp/empty /tmp/absent/worlds \
  && cp /tmp/set/worlds/$TAR /tmp/absent/worlds/ \
  && printf 'x\n' > /tmp/absent/mysql.sql \
  && { $NOW; printf 'mysql_database: riftal_smoke_absent\n'; } > /tmp/absent/manifest.txt \
  && cp /tmp/set/mysql.sql /tmp/other/ && printf 'mysql_database: riftal_other\n' > /tmp/other/manifest.txt \
  && for s in noworlds notars badtar; do mkdir -p /tmp/\$s && cp /tmp/set/mysql.sql /tmp/set/manifest.txt /tmp/\$s/; done \
  && mkdir -p /tmp/notars/worlds /tmp/badtar/worlds && printf 'x\n' > /tmp/notars/worlds/level.dat \
  && cp /tmp/set/worlds/$TAR /tmp/badtar/worlds/ && printf 'not a tar\n' > /tmp/badtar/worlds/riftal_smoke_vol_z.tar.gz"
# One set per way its timestamp can fail, each otherwise valid for $DB, and a
# two-hour-old set naming the absent database, which can pass the age check
# with no wipe to follow it.
stamped() {
  sh_in "mkdir -p /tmp/$1 && cp -r /tmp/absent/mysql.sql /tmp/absent/worlds /tmp/$1/ \
    && { $2; printf 'mysql_database: %s\n' '${3:-$DB}'; } > /tmp/$1/manifest.txt"
}
stamped stale "$(stamp_cmd '-2 hours')"
stamped future "$(stamp_cmd '+2 hours')"
stamped nostamp true
stamped twostamps "$NOW; $NOW"
stamped badformat "echo 'timestamp: 2026-10-10T00:00:00Z'"
stamped badtime "echo 'timestamp: 20261340T250000000000000Z'"
stamped stale_absent "$(stamp_cmd '-2 hours')" riftal_smoke_absent
# A stale set that also holds a tar that does not list, so only a wipe that
# refuses on age before it reads any tar names the age.
stamped stale_badtar "$(stamp_cmd '-2 hours')"
sh_in "cp /tmp/badtar/worlds/riftal_smoke_vol_z.tar.gz /tmp/stale_badtar/worlds/"
# backup.sh's stamp with a nanosecond digit too few and one too many. Each
# names the absent database, so a format check that let it through reaches
# that refusal rather than a wipe of the fixture.
stamped eightnanos "sed -n '/^timestamp: /s/[0-9]Z\$/Z/p' /tmp/set/manifest.txt" riftal_smoke_absent
stamped tennanos "sed -n '/^timestamp: /s/Z\$/0Z/p' /tmp/set/manifest.txt" riftal_smoke_absent

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=50
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
refused stale-set "1[0-9][0-9] minute(s) old, over WIPE_BACKUP_MAX_AGE_MINUTES=60" wipe "$DB" "$DB" /tmp/stale
refused stale-set-unread-tars "1[0-9][0-9] minute(s) old, over WIPE_BACKUP_MAX_AGE_MINUTES=60" wipe "$DB" "$DB" /tmp/stale_badtar
refused future-set "7[12][0-9][0-9]s in the future by this host's clock; if backup.sh ran on another host, its clock is ahead of this one" \
  wipe "$DB" "$DB" /tmp/future
refused no-timestamp "holds 0 timestamp line(s)" wipe "$DB" "$DB" /tmp/nostamp
refused two-timestamps "holds 2 timestamp line(s)" wipe "$DB" "$DB" /tmp/twostamps
refused bad-format "not in backup.sh's format" wipe "$DB" "$DB" /tmp/badformat
refused bad-time "not a valid UTC time" wipe "$DB" "$DB" /tmp/badtime
refused eight-nanos "not in backup.sh's format" wipe riftal_smoke_absent riftal_smoke_absent /tmp/eightnanos
refused ten-nanos "not in backup.sh's format" wipe riftal_smoke_absent riftal_smoke_absent /tmp/tennanos
# backup.sh's stamp is UTC whatever TZ it ran under, so a fresh set passes the
# age check, reaching the absent database, under a zone either side of UTC.
WIPE_TZ=RIFT-14 refused tz-east-fresh "no database riftal_smoke_absent" \
  wipe riftal_smoke_absent riftal_smoke_absent /tmp/absent
WIPE_TZ=RIFT+12 refused tz-west-fresh "no database riftal_smoke_absent" \
  wipe riftal_smoke_absent riftal_smoke_absent /tmp/absent
WIPE_MAX_AGE=0 refused zero-max-age "must be a whole number" wipe "$DB" "$DB" /tmp/set
WIPE_MAX_AGE=1h refused unit-max-age "must be a whole number" wipe "$DB" "$DB" /tmp/set
WIPE_MAX_AGE=180 refused raised-max-age "no database riftal_smoke_absent" \
  wipe riftal_smoke_absent riftal_smoke_absent /tmp/stale_absent

# Each hold aliases its SLEEP with its own tag, so hold() and released() count
# that session and never one an earlier hold left behind.
HOLDS=0
HOLD_TAG=
sleeping() { q "SELECT COUNT(*) FROM performance_schema.processlist WHERE INFO LIKE 'SELECT SLEEP(% AS $HOLD_TAG'"; }
# A session that never connects would let the next refusal case run a real
# wipe on the fixture, so it stops the self-test rather than muddy every later
# assertion. The session ends only when released() kills it: a hold that timed
# itself out could end on a slow runner while a refusal case still needed it,
# and that case's wipe would drop the fixture. The SLEEP length only bounds a
# hold that released() never reaches.
hold() {
  HOLDS=$((HOLDS + 1))
  HOLD_TAG="held$HOLDS"
  docker exec -d "$C" mysql -uroot -pselftest "$@" -e "SELECT SLEEP(600) AS $HOLD_TAG"
  for _ in $(seq 1 20); do [ "$(sleeping)" = "1" ] && return; sleep 0.5; done
  echo "the session $HOLD_TAG held on $C with default database '${1:-none}' never connected" >&2
  exit 1
}
# A session still connected, or a count that cannot be read, would let the next
# hold's refusal case pass against this session rather than its own, so either
# stops the self-test.
released() {
  local id n=
  id="$(q "SELECT ID FROM performance_schema.processlist WHERE INFO LIKE 'SELECT SLEEP(% AS $HOLD_TAG'")" || id=
  case "$id" in
    '' | *[!0-9]*)
      echo "the session $HOLD_TAG held on $C was not connected to be released; its id read '${id:-unreadable}'" >&2
      exit 1
      ;;
  esac
  q "KILL $id" || { echo "the session $HOLD_TAG held on $C, id $id, could not be killed" >&2; exit 1; }
  for _ in $(seq 1 30); do
    n="$(sleeping)" || n=
    [ "$n" = "0" ] && return
    sleep 0.5
  done
  echo "the session $HOLD_TAG held on $C never ended; its count read '${n:-unreadable}'" >&2
  exit 1
}

# An account with every privilege on the schema but no PROCESS sees only its
# own threads in the processlist, so it would count 0 with a session connected.
q "CREATE USER 'wiper'@'%' IDENTIFIED BY 'selftest'; GRANT ALL ON $DB.* TO 'wiper'@'%'"
# PROCESS through a role counts only while the role is active in the session,
# which a default role is at login and a granted, non-default one is not.
q "CREATE ROLE 'riftal_smoke_process'; GRANT PROCESS ON *.* TO 'riftal_smoke_process';
   CREATE USER 'role_wiper'@'%' IDENTIFIED BY 'selftest', 'idle_role_wiper'@'%' IDENTIFIED BY 'selftest';
   GRANT ALL ON $DB.* TO 'role_wiper'@'%', 'idle_role_wiper'@'%';
   GRANT 'riftal_smoke_process' TO 'role_wiper'@'%', 'idle_role_wiper'@'%';
   SET DEFAULT ROLE 'riftal_smoke_process' TO 'role_wiper'@'%'"
# wipe.sh finds PROCESS on the SHOW GRANTS line MySQL 8 prints for the static
# global privileges. A direct grant among others, and a grant of every
# privilege, must each reach the session refusal, so a release that prints the
# line differently fails them naming PROCESS. Nothing here asserts which
# alternative of wipe.sh's grep allpriv_wiper matches: that depends on how the
# MySQL release the fixture runs prints GRANT ALL ON *.*, either as each static
# privilege by name or as ALL PRIVILEGES.
q "CREATE USER 'direct_wiper'@'%' IDENTIFIED BY 'selftest', 'allpriv_wiper'@'%' IDENTIFIED BY 'selftest';
   GRANT ALL ON $DB.* TO 'direct_wiper'@'%';
   GRANT SELECT, PROCESS, RELOAD ON *.* TO 'direct_wiper'@'%';
   GRANT ALL PRIVILEGES ON *.* TO 'allpriv_wiper'@'%'"
hold "$DB"
refused connected-session "other session(s) are connected to .*; close every other connection, instances first" wipe "$DB" "$DB" /tmp/set
WIPE_USER=role_wiper refused role-process-session "1 other session(s) are connected" wipe "$DB" "$DB" /tmp/set
WIPE_USER=direct_wiper refused direct-process-session "1 other session(s) are connected" wipe "$DB" "$DB" /tmp/set
WIPE_USER=allpriv_wiper refused all-privileges-session "1 other session(s) are connected" wipe "$DB" "$DB" /tmp/set
released
# A held session backstops three cases, no-worlds-dir, no-world-tars and
# bad-world-tar below. Each runs as root, which sees the session, so a wipe.sh
# that missed the check under test is refused for the session instead and fails
# the case without a drop. Nothing backs the six session cases, connected-session,
# role-process-session, direct-process-session, all-privileges-session,
# no-default-db-session and other-db-session: each expects the session refusal,
# so a regression in the session count at wipe.sh would drop the fixture. The
# cases before the first hold run with no session held, so they have no backstop
# either.
# psoff-session runs on $C_PSOFF, where a session on $C protects nothing. The
# no-PROCESS cases run below the confirmed wipe.
hold "$DB"
refused no-worlds-dir "has no worlds/ directory, so restore.sh" wipe "$DB" "$DB" /tmp/noworlds
refused no-world-tars "worlds holds no .tar.gz, so restore.sh" wipe "$DB" "$DB" /tmp/notars
refused bad-world-tar "riftal_smoke_vol_z.tar.gz does not list with tar -tzf, so restore.sh" \
  wipe "$DB" "$DB" /tmp/badtar
released
hold
refused no-default-db-session "other session" wipe "$DB" "$DB" /tmp/set
released
hold mysql
refused other-db-session "other session" wipe "$DB" "$DB" /tmp/set
released

[ "$(snapshot_rows)" = "2" ] && pass "every refusal left the snapshot rows in place" \
  || fail "a refused wipe changed the database"

printf '\n== a confirmed wipe, then the migrations, leaves every table empty\n'
# The confirmed wipe passing proves wipe.sh leaves Daemon threads out of its
# count only while one is connected, which on mysql:8 rests on the default
# event_scheduler=ON.
daemons="$(q "SELECT COUNT(*) FROM performance_schema.processlist WHERE COMMAND = 'Daemon'")"
[ "${daemons:-0}" -ge 1 ] && pass "a Daemon thread is connected, $daemons of them" \
  || fail "no Daemon thread is connected, so the confirmed wipe cannot show they are left out of the count"
wipe_ok=1
wipe_set=/tmp/set
wipe "$DB" "$DB" "$wipe_set" >"$LOGS/wipe.log" 2>"$LOGS/wipe.err" || wipe_ok=0
if [ "$wipe_ok" -eq 1 ]; then
  pass "the confirmed wipe exits 0"
else
  fail "the confirmed wipe should exit 0"; cat "$LOGS/wipe.log" "$LOGS/wipe.err"
fi
# A stray command in wipe.sh whose failure set -e does not stop, for example
# one ahead of it or inside a condition, leaves the exit status at 0, so only
# its output shows it.
if [ -s "$LOGS/wipe.err" ]; then
  fail "the confirmed wipe wrote to stderr; any stderr fails this, a mysql client warning included"
  # A failed wipe has printed wipe.err above.
  if [ "$wipe_ok" -eq 1 ]; then cat "$LOGS/wipe.err"; fi
else
  pass "the confirmed wipe writes nothing to stderr"
fi
{
  printf 'wipe %s: volume riftal_smoke_vol: cleared 0 level(s) and the contents of players/ and plugin_data/\n' "$DB"
  printf 'wipe %s: dropping and recreating at %s:%s, backup set %s\nwipe %s: complete, empty; run ../migrations/run-migrations.sh, then wipe-check.sh\n' \
    "$DB" "$MYSQL_HOST" "$DOCUMENTED_DEFAULT_PORT" "$wipe_set" "$DB"
} >"$LOGS/wipe.expected"
if cmp -s "$LOGS/wipe.expected" "$LOGS/wipe.log"; then
  pass "the confirmed wipe's stdout is exactly its three progress lines"
else
  fail "the confirmed wipe's stdout is not exactly its three progress lines"
  # A failed wipe has printed wipe.log above.
  if [ "$wipe_ok" -eq 1 ]; then diff "$LOGS/wipe.expected" "$LOGS/wipe.log" || true; fi
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
grep -qx "wipe-check $DB: ok, 2 migration(s) applied, 4 table(s) empty but for 1 seeded row(s)" "$LOGS/check-wiped.log" \
  && pass "wipe-check's ok line counts the seeded capture_fence row" || { fail "wipe-check's ok line"; cat "$LOGS/check-wiped.log"; }
FENCE="capture_fence should hold only migration 0027's row, id 1 and lowered"
fence_fails() {
  if check >"$LOGS/check-fence-$1.log" 2>&1; then
    fail "wipe-check passed with capture_fence $1"
  elif grep -qF "FAIL $FENCE; it holds $2" "$LOGS/check-fence-$1.log"; then
    pass "wipe-check fails with capture_fence $1"
  else
    fail "wipe-check failed with capture_fence $1 without naming it"; cat "$LOGS/check-fence-$1.log"
  fi
}
q "UPDATE $DB.capture_fence SET request_id = 'r1', raised_until = UTC_TIMESTAMP(3) + INTERVAL 60 SECOND"
fence_fails raised "1 row(s), 0 of them that row"
q "DELETE FROM $DB.capture_fence"
fence_fails empty "0 row(s), 0 of them that row"
q "INSERT INTO $DB.capture_fence (id) VALUES (1)"
# A table list that cannot be read, or reads as nothing, checks no table at all,
# so it must fail rather than pass as zero tables all empty. The first mysql on
# PATH fails only the table-list query, as a dropped connection would; the
# account sees schema_migrations alone, so the list it reads is empty.
sh_in "mkdir -p /tmp/failing-bin && printf '%s\n' '#!/bin/bash' \
  'case \"\$*\" in *information_schema.TABLES*) echo \"ERROR 2013 (HY000): Lost connection\" >&2; exit 1;; esac' \
  'exec /usr/bin/mysql \"\$@\"' > /tmp/failing-bin/mysql && chmod +x /tmp/failing-bin/mysql"
q "CREATE USER 'listless'@'%' IDENTIFIED BY 'selftest'; GRANT SELECT ON $DB.schema_migrations TO 'listless'@'%'"
unlisted_fails() {
  local name="$1" reason="$2"
  shift 2
  if check "$@" >"$LOGS/check-$name.log" 2>&1; then
    fail "wipe-check passed when $name"; cat "$LOGS/check-$name.log"
  elif grep -qF "FAIL $reason" "$LOGS/check-$name.log"; then
    pass "wipe-check fails when $name"
  else
    fail "wipe-check failed when $name without saying so"; cat "$LOGS/check-$name.log"
  fi
}
unlisted_fails "the table-list query fails" "could not list the tables" \
  -e PATH=/tmp/failing-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
unlisted_fails "the table list is empty" "information_schema lists no table but schema_migrations" -e MYSQL_USER=listless
[ "$(snapshot_rows)" = "0" ] && pass "economy_balance_snapshot exists and is empty" \
  || fail "economy_balance_snapshot should exist and be empty, got '$(snapshot_rows)'"
[ "$(q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$DB' AND TABLE_NAME = 'stray_unmigrated'")" = "0" ] \
  && pass "a table no migration creates is gone" || fail "stray_unmigrated survived the wipe"

# wiper and idle_role_wiper cannot see a held session, so a wipe.sh that
# accepted either would drop the database. They run here, after every assertion
# that needs the fixture's contents, and a marker row shows it was not dropped.
# The session is held for a wipe.sh that activated the role for idle_role_wiper:
# that account would then see it and be refused for the session, which fails the
# case without a drop.
q "INSERT INTO $DB.balances VALUES (7, 7)"
hold "$DB"
WIPE_USER=wiper refused no-process "lacks PROCESS, directly or through an active role" wipe "$DB" "$DB" /tmp/set
WIPE_USER=idle_role_wiper refused inactive-role-process "lacks PROCESS, directly or through an active role" \
  wipe "$DB" "$DB" /tmp/set
released
[ "$(q "SELECT balance_minor_units FROM $DB.balances WHERE account_id = 7")" = "7" ] \
  && pass "the no-PROCESS refusals left the database in place" || fail "a no-PROCESS refusal dropped the database"

printf '\n== with performance_schema off, a connected session still refuses the wipe\n'
qp() { docker exec "$C_PSOFF" mysql -uroot -pselftest -N -B -e "$1" 2>/dev/null; }
qp "CREATE TABLE $DB.t (id INT PRIMARY KEY); INSERT INTO $DB.t VALUES (1), (2), (3)"
docker exec "$C_PSOFF" bash -c "mkdir -p /tmp/set/worlds /tmp/vol && printf 'x\n' > /tmp/set/mysql.sql \
  && printf 'x\n' > /tmp/vol/level.dat && tar -czf /tmp/set/worlds/$TAR -C /tmp/vol ."
docker exec "$C" cat /tmp/set/manifest.txt | docker exec -i "$C_PSOFF" bash -c 'cat > /tmp/set/manifest.txt'
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
