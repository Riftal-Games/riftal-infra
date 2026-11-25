#!/usr/bin/env bash
# Self-test for the script-driven exits of the level replace runbook
# (riftal-infra#1387, ADR 027): step 2 taking a verified set, step 2 refused by the
# database login, the whole-set rollback with restore.sh, restore.sh lowering the
# capture fence the set carries, and the first run after that restore completing at
# once. It also runs step 2's set check on a set too large for a pipe buffer.
#
# It runs only as a CI step. ADR 027 forbids any agent running backup.sh or
# restore.sh by hand, on any volume. Each scenario owns a throwaway mysql:8 container,
# network and two volumes, all named riftal_smoke_lvr_*, and removes them on exit.
#
# The first scenario runs the real scripts and must pass every case. Each later
# scenario runs the same cases against a one-line mutant of backup.sh or restore.sh and
# must fail exactly the cases named beside it, so the log shows every case going red.
# Scenarios run a few at a time; each has its own mysql, since restore.sh refuses while
# any other session is connected.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX="$$-$(date +%s)"
EXPECTED_CASES=17
JOBS=7

# The tree hash of step 4 of the runbook, over the zone folder of a mounted volume.
TREE='cd /data/worlds/mine_a && find . -type f -printf "%P\0" | LC_ALL=C sort -z | xargs -0 -r sha256sum -- | sha256sum | cut -d" " -f1'

# The verification of step 2 of the runbook, as written there.
VERIFY_SET_SCRIPT='
      set -euo pipefail
      cd "/backups/$SET"
      [ -s mysql.sql ] || { echo "mysql.sql is missing or empty"; exit 1; }
      grep -q "^  - $VOL:" manifest.txt || { echo "manifest.txt does not list $VOL"; exit 1; }
      for t in worlds/*.tar.gz; do tar -tzf "$t" >/dev/null; echo "ok $t"; done
      # No -q: grep reads the whole listing, so tar never takes SIGPIPE under pipefail.
      tar -tzf "worlds/$VOL.tar.gz" | grep -x "./worlds/$ZONE/level.dat" >/dev/null || { echo "the tar holds no $ZONE"; exit 1; }
      echo "set $SET verified"'

WORK="$(mktemp -d)"
# backup.sh and restore.sh test server.lock with flock, which mysql:8 does not
# carry. A restore leaves a server.lock in the volume, so every run after one needs it.
BACKUP_IMG="riftal_smoke_lvr_img:$SUFFIX"
trap 'rm -rf "$WORK"; docker image rm "$BACKUP_IMG" >/dev/null 2>&1' EXIT
docker build -q -t "$BACKUP_IMG" "$SCRIPT_DIR/../images/backup" >/dev/null || { echo "building the backup image failed" >&2; exit 1; }

# $1 scenario id, $2 the backup.sh to run, $3 the restore.sh to run. Prints one
# "  ok" or "FAILCASE" line per case, in a fixed order.
scenario() (
  id="$1" backup_sh="$2" restore_sh="$3"
  net="riftal_smoke_lvr_net_$SUFFIX-$id"
  db_c="riftal_smoke_lvr_mysql_$SUFFIX-$id"
  sets="riftal_smoke_lvr_sets_$SUFFIX-$id"
  inst="riftal_smoke_lvr_inst_$SUFFIX-$id"
  logs="$WORK/$id.logs"
  mkdir -p "$logs"

  cleanup() {
    docker rm -f -v "$db_c" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
    docker volume rm "$sets" "$inst" >/dev/null 2>&1
  }
  trap cleanup EXIT

  pass() { printf '  ok    %s\n' "$1"; }
  fail() { printf 'FAILCASE %s\n' "$1"; }
  setup_failed() { printf 'SETUP-FAILED %s\n' "$1"; exit 1; }

  sql() { docker exec "$db_c" mysql -uroot -pselftest -N -B riftal_selftest -e "$1"; }
  inst_sh() { docker run --rm -m 1g --cpus 1 -v "$inst:/data" mysql:8 bash -c "$1"; }
  sets_sh() { docker run --rm -m 1g --cpus 1 -v "$sets:/backups" mysql:8 bash -c "$1"; }
  tree_of() { inst_sh "$TREE" 2>/dev/null; }
  # Runs in the scenario's own shell, not a substitution, so a failed listing ends
  # the scenario instead of reading as no sets.
  load_sets() { SET_LIST="$(sets_sh 'ls -1 /backups' 2>/dev/null)" || setup_failed "listing the sets volume failed"; }
  count_sets() { printf '%s\n' "$SET_LIST" | grep -cE '^[0-9]+T[0-9]+Z$'; }
  count_partials() { printf '%s\n' "$SET_LIST" | grep -c '\.partial$'; }

  # Fence lease 600s: a fence the restore left raised is still live when the first
  # run after it asks, however slow the runner. The hold is 2s because no instance
  # runs.
  run_backup() {
    docker run --rm -m 1g --cpus 1 --network "$net" \
      -v "$backup_sh:/deploy/backup.sh:ro" -v "$sets:/backups" \
      -v "$inst:/worlds/$inst:ro" \
      -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$1" \
      -e MYSQL_DATABASE=riftal_selftest -e BACKUP_RETENTION=10 \
      -e CAPTURE_HOLD_MAX_SECONDS=2 -e CAPTURE_FENCE_MAX_SECONDS=600 \
      "$BACKUP_IMG" bash /deploy/backup.sh
  }

  run_restore() {
    docker run --rm -m 1g --cpus 1 --network "$net" \
      -v "$restore_sh:/deploy/restore.sh:ro" -v "$sets:/backups:ro" \
      -v "$inst:/worlds/$inst" \
      -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD=selftest \
      -e MYSQL_DATABASE=riftal_selftest -e BACKUP_SET="/backups/$1" \
      "$BACKUP_IMG" bash /deploy/restore.sh
  }

  verify_set() {
    docker run --rm -m 1g --cpus 1 -v "$sets:/backups:ro" -e SET="$1" -e VOL="$inst" -e ZONE=mine_a mysql:8 bash -c "$VERIFY_SET_SCRIPT"
  }

  docker network create "$net" >/dev/null || setup_failed "network"
  docker volume create "$sets" >/dev/null || setup_failed "sets volume"
  docker volume create "$inst" >/dev/null || setup_failed "instance volume"
  docker run -d --rm -m 1g --cpus 1 --name "$db_c" --network "$net" --network-alias mysql \
    -e MYSQL_ROOT_PASSWORD=selftest -e MYSQL_DATABASE=riftal_selftest \
    mysql:8 >/dev/null || setup_failed "mysql container"
  ready=0
  for _ in $(seq 1 90); do
    if docker exec "$db_c" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || setup_failed "mysql never became ready"

  docker exec -i "$db_c" mysql -uroot -pselftest riftal_selftest <"$SCRIPT_DIR/fence-fixture.sql" >/dev/null 2>&1 \
    || setup_failed "fence fixture"
  sql 'CREATE TABLE marker (id INT PRIMARY KEY, note VARCHAR(64)); INSERT INTO marker VALUES (1, "at-set")' \
    >/dev/null 2>&1 || setup_failed "marker row"
  inst_sh 'mkdir -p /data/worlds/mine_a/db && echo level-at-set > /data/worlds/mine_a/level.dat && echo region-at-set > /data/worlds/mine_a/db/000001.ldb' \
    >/dev/null 2>&1 || setup_failed "level folder"
  pre_tree="$(tree_of)"
  [ -n "$pre_tree" ] || setup_failed "no tree hash before the set"

  run_backup selftest >"$logs/set.log" 2>&1
  rc=$?
  [ "$rc" = 0 ] && pass set-run-exit0 || fail set-run-exit0
  set_ts="$(sed -n 's|^backup [^ ]*: complete at /backups/\([^ ]*\)$|\1|p' "$logs/set.log")"
  set_fs="$(sets_sh 'ls -1 /backups' 2>/dev/null | grep -E '^[0-9]+T[0-9]+Z$' | head -n 1)"
  [ -n "$set_ts" ] && [ "$set_ts" = "$set_fs" ] && pass set-complete-line || fail set-complete-line
  verify_set "$set_ts" >"$logs/verify.log" 2>&1
  rc=$?
  [ "$rc" = 0 ] && grep -qx "set $set_ts verified" "$logs/verify.log" && pass set-verified || fail set-verified

  load_sets
  sets_before="$(count_sets)"
  run_backup wrong-password >"$logs/refused.log" 2>&1
  rc=$?
  [ "$rc" != 0 ] && pass refused-exit-nonzero || fail refused-exit-nonzero
  [ "$(grep -c 'complete at' "$logs/refused.log")" = 0 ] && pass refused-no-complete-line || fail refused-no-complete-line
  grep -q '^backup [^ ]*: failed, exit 1$' "$logs/refused.log" && pass refused-failed-line || fail refused-failed-line
  load_sets
  [ "$(count_sets)" = "$sets_before" ] && pass refused-no-new-set || fail refused-no-new-set
  [ "$(count_partials)" = 0 ] && pass refused-no-partial || fail refused-no-partial

  inst_sh 'cd /data/worlds && mv mine_a .replaced-mine_a-selftest && mkdir mine_a && echo level-after-swap > mine_a/level.dat && echo extra > mine_a/extra.dat' \
    >/dev/null 2>&1 || setup_failed "swap"
  sql 'UPDATE marker SET note = "after-swap" WHERE id = 1' >/dev/null 2>&1 || setup_failed "marker update"
  post_tree="$(tree_of)"
  { [ -n "$post_tree" ] && [ "$post_tree" != "$pre_tree" ]; } || setup_failed "the swap did not change the level"

  run_restore "$set_fs" >"$logs/restore.log" 2>&1
  rc=$?
  [ "$rc" = 0 ] && pass restore-exit0 || fail restore-exit0
  grep -q 'restore /backups/[^ ]*: complete, database riftal_selftest and 1 world volume(s) rebuilt' "$logs/restore.log" \
    && pass restore-complete-line || fail restore-complete-line
  [ "$(sql 'SELECT note FROM marker WHERE id = 1' 2>/dev/null)" = at-set ] && pass restore-row-at-set || fail restore-row-at-set
  [ "$(tree_of)" = "$pre_tree" ] && pass restore-level-tree || fail restore-level-tree
  [ "$(inst_sh 'ls -A /data/worlds' 2>/dev/null)" = mine_a ] && pass restore-volume-rebuilt || fail restore-volume-rebuilt

  # The set was dumped while its own run held the fence, so the restored row is
  # raised until restore.sh lowers it.
  [ "$(sql 'SELECT COUNT(*) FROM capture_fence WHERE id = 1 AND request_id IS NULL AND raised_until IS NULL' 2>/dev/null)" = 1 ] \
    && pass restore-fence-lowered || fail restore-fence-lowered

  load_sets
  sets_before="$(count_sets)"
  run_backup selftest >"$logs/first.log" 2>&1
  rc=$?
  [ "$rc" = 0 ] && pass first-run-exit0 || fail first-run-exit0
  grep -q '^backup [^ ]*: complete at /backups/' "$logs/first.log" && pass first-run-complete-line || fail first-run-complete-line
  load_sets
  [ "$(count_sets)" = "$((sets_before + 1))" ] && pass first-run-new-set || fail first-run-new-set
)

# Step 2 on a set whose level listing outgrows a pipe buffer. A pipeline whose grep
# exits on its first match leaves tar writing into a closed pipe, and pipefail reads
# that SIGPIPE as a missing level. The run with the early-exit form must fail and the
# run with the runbook's form must pass, so the log shows the case able to go red.
SIGPIPE_FAILS=0
sigpipe_set_check() {
  local new_line old_line old_script out rc
  new_line='tar -tzf "worlds/$VOL.tar.gz" | grep -x "./worlds/$ZONE/level.dat" >/dev/null'
  old_line='tar -tzf "worlds/$VOL.tar.gz" | grep -qx "./worlds/$ZONE/level.dat"'
  old_script="${VERIFY_SET_SCRIPT/"$new_line"/"$old_line"}"
  if [ "$old_script" = "$VERIFY_SET_SCRIPT" ]; then
    printf '::error::the early-exit form did not apply\n'; SIGPIPE_FAILS=$((SIGPIPE_FAILS + 1)); return
  fi
  run_big_set() {
    docker run --rm -m 1g --cpus 1 -e SCRIPT="$1" -e SET=S -e VOL=riftal_smoke_lvr_big -e ZONE=mine_a mysql:8 bash -c '
      set -euo pipefail
      mkdir -p "/src/worlds/$ZONE" /backups/S/worlds
      echo set > /backups/S/mysql.sql
      printf "  - %s: 1 bytes\n" "$VOL" > /backups/S/manifest.txt
      echo level > "/src/worlds/$ZONE/level.dat"
      long="$(printf "z%.0s" $(seq 200))"
      for i in $(seq 1500); do : > "/src/worlds/$ZONE/$long$i"; done
      tar --sort=name -czf "/backups/S/worlds/$VOL.tar.gz" -C /src .
      bash -c "$SCRIPT"' 2>&1
  }
  out="$(run_big_set "$old_script")"; rc=$?
  if [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -qx 'the tar holds no mine_a'; then
    printf '  ok    the early-exit form fails a good set, exit %s\n' "$rc"
  else
    printf '::error::the early-exit form did not fail the large set (exit %s)\n%s\n' "$rc" "$out"
    SIGPIPE_FAILS=$((SIGPIPE_FAILS + 1))
  fi
  out="$(run_big_set "$VERIFY_SET_SCRIPT")"; rc=$?
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'set S verified'; then
    printf '  ok    the runbook form verifies the large set\n'
  else
    printf '::error::the runbook form did not verify the large set (exit %s)\n%s\n' "$rc" "$out"
    SIGPIPE_FAILS=$((SIGPIPE_FAILS + 1))
  fi
}

IDS=() EXPECT=() BACKUP_SH=() RESTORE_SH=()
PREP_FAILURES=0

# $1 id, $2 the script to mutate, $3 the text to replace, $4 its replacement, $5 the
# cases it must fail, in order, and no others.
mutant() {
  local from="$SCRIPT_DIR/$2" file="$WORK/$1.$2" src mutated
  src="$(cat "$from")"
  mutated="${src/"$3"/"$4"}"
  if [ "$mutated" = "$src" ]; then
    printf '::error::mutant %s did not apply\n' "$1"; PREP_FAILURES=$((PREP_FAILURES + 1)); return
  fi
  printf '%s\n' "$mutated" >"$file"
  IDS+=("$1") EXPECT+=("$5")
  if [ "$2" = backup.sh ]; then
    BACKUP_SH+=("$file") RESTORE_SH+=("$SCRIPT_DIR/restore.sh")
  else
    BACKUP_SH+=("$SCRIPT_DIR/backup.sh") RESTORE_SH+=("$file")
  fi
}

IDS+=(clean) EXPECT+=("") BACKUP_SH+=("$SCRIPT_DIR/backup.sh") RESTORE_SH+=("$SCRIPT_DIR/restore.sh")

mutant exit-after-publish backup.sh \
  'echo "backup $ts: applying retention, keeping the last $BACKUP_RETENTION"' 'exit 3' \
  "set-run-exit0 first-run-exit0"
mutant complete-line-renamed backup.sh \
  'echo "backup $ts: complete at $set_dir"' 'echo "backup $ts: done at $set_dir"' \
  "set-complete-line set-verified first-run-complete-line"
mutant manifest-omits-volume backup.sh \
  'echo "  - $name: $(wc -c < "$tmp_dir/worlds/$name.tar.gz") bytes"' 'true' \
  "set-verified"
mutant tar-omits-level backup.sh \
  '--exclude=./.capture -C "$vol" . || rc=$?' '--exclude=./.capture --exclude=./worlds -C "$vol" . || rc=$?' \
  "set-verified restore-level-tree restore-volume-rebuilt"
mutant failure-exits-zero backup.sh \
  $'  echo "backup $ts: $1" >&2\n  exit 1' $'  echo "backup $ts: $1" >&2\n  exit 0' \
  "refused-exit-nonzero refused-failed-line refused-no-partial"
mutant failure-claims-complete backup.sh \
  'echo "backup $ts: $1" >&2' 'echo "backup $ts: complete at $set_dir, then $1" >&2' \
  "refused-no-complete-line"
mutant failure-publishes-partial backup.sh \
  'rm -rf "$tmp_dir"' 'mv "$tmp_dir" "$set_dir"' \
  "refused-no-new-set"
mutant restore-noop restore.sh \
  'echo "restore $BACKUP_SET: rebuilding database $MYSQL_DATABASE at $MYSQL_HOST:$MYSQL_PORT"' 'exit 0' \
  "restore-complete-line restore-row-at-set restore-level-tree restore-volume-rebuilt"
mutant restore-merges-volume restore.sh \
  'find "$target" -mindepth 1 ! -path "$target/server.lock" -delete' 'true' \
  "restore-level-tree restore-volume-rebuilt"
mutant restore-loads-nothing restore.sh \
  '< "$BACKUP_SET/mysql.sql"' '< /dev/null' \
  "restore-exit0 restore-complete-line restore-row-at-set restore-level-tree restore-volume-rebuilt restore-fence-lowered first-run-exit0 first-run-complete-line first-run-new-set"
mutant restore-exits-nonzero restore.sh \
  'echo "restore $BACKUP_SET: complete, database' 'exit 4; echo "restore $BACKUP_SET: complete, database' \
  "restore-exit0 restore-complete-line"
mutant restore-keeps-fence restore.sh \
  'if [ "$fenced" = 1 ]; then' 'if false; then' \
  "restore-fence-lowered first-run-exit0 first-run-complete-line first-run-new-set"

[ "$PREP_FAILURES" = 0 ] || exit 1

running=0
for i in "${!IDS[@]}"; do
  scenario "${IDS[i]}" "${BACKUP_SH[i]}" "${RESTORE_SH[i]}" >"$WORK/${IDS[i]}.out" 2>"$WORK/${IDS[i]}.err" &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then
    wait -n
    running=$((running - 1))
  fi
done
wait

FAILURES=0 PASSES=0
for i in "${!IDS[@]}"; do
  out="$WORK/${IDS[i]}.out"
  if [ "${IDS[i]}" = clean ]; then
    printf '\n== the real scripts\n'
  else
    printf '\n== mutant %s\n' "${IDS[i]}"
  fi
  cat "$out"
  shown=$(grep -cE '^(  ok|FAILCASE) ' "$out")
  got="$(sed -n 's/^FAILCASE \(.*\)$/\1/p' "$out" | tr '\n' ' ')"
  if [ "${got% }" = "${EXPECT[i]}" ] && [ "$shown" -eq "$EXPECTED_CASES" ]; then
    if [ "${IDS[i]}" = clean ]; then
      printf '  ok    the real scripts pass all %s cases\n' "$EXPECTED_CASES"
    else
      printf '  ok    mutant %s fails: %s\n' "${IDS[i]}" "${EXPECT[i]}"
    fi
    PASSES=$((PASSES + 1))
  else
    printf '::error::%s failed "%s" of %s cases, wanted "%s"\n' "${IDS[i]}" "${got% }" "$shown" "${EXPECT[i]}"
    FAILURES=$((FAILURES + 1))
    cat "$WORK/${IDS[i]}.err"
    for f in "$WORK/${IDS[i]}.logs"/*.log; do
      [ -f "$f" ] || continue
      printf -- '--- %s\n' "${f##*/}"
      cat "$f"
    done
  fi
done

printf '\n== step 2 set check on a large listing\n'
sigpipe_set_check
FAILURES=$((FAILURES + SIGPIPE_FAILS))

if [ "$FAILURES" -ne 0 ]; then
  printf '\n%s scenario(s) did not end as expected\n' "$FAILURES"
  exit 1
fi
printf '\nall %s scenarios ended as expected: the real scripts pass %s cases and each of %s mutants fails exactly its own\n' \
  "$PASSES" "$EXPECTED_CASES" "$((PASSES - 1))"
