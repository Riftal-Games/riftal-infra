#!/usr/bin/env bash
# Self-test for capture-cost.sh: each figure and each refusal is read from a log
# written here, so a rule that stops failing is caught before the harness relies on it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/capture-cost.sh"

FAILURES=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 case, $2 wanted output, the rest a command.
expect() {
  local what=$1 want=$2 got
  shift 2
  got="$("$@")"
  if [ "$got" = "$want" ]; then
    printf '  ok    %s\n' "$what"
  else
    printf '::error::%s: wanted "%s", got "%s"\n' "$what" "$want" "$got"
    FAILURES=$((FAILURES + 1))
  fi
}

# $1 case, $2 wanted status (holds or refused), $3 a log.
rule() {
  local what=$1 want=$2 status=holds
  run_follows_listing_rule "$3" || status=refused
  if [ "$status" = "$want" ]; then
    printf '  ok    %s\n' "$what"
  else
    printf '::error::%s: wanted %s, got %s\n' "$what" "$want" "$status"
    FAILURES=$((FAILURES + 1))
  fi
}

# $1 a file, the rest its lines after "backup T: ".
backup_log() {
  local file=$1 line
  shift
  for line in "$@"; do printf 'backup T: %s\n' "$line"; done >"$file"
}

done_line='complete at /backups/T'
change='volume a changed during its tar'
backup_log "$work/clean" 'volume a is held for request r' 'tar of volume a, held, exited 0' "$done_line"
backup_log "$work/retry" "$change" 'volume a before its tar: worlds/world/db/000003.log 8 1.5' \
  'volume a after its tar: worlds/world/db/000005.ldb 9 2.5' 'volume a after its tar: .capture 4096 2.5' \
  'volume a after its tar: server.lock 1 2.5' 'volume a is held for request r' "$done_line"
backup_log "$work/twice" "$change" 'volume a before its tar: worlds 4096 1.5' "$change" \
  'volume a after its tar: .capture/r/ack 34 2.5' 'volume a changed during its tar twice, no set is written'
backup_log "$work/outside" "$change" 'volume a before its tar: players/p1.dat 9 1.5' "$done_line"
backup_log "$work/nowhere" "$change" "$done_line"
backup_log "$work/lookalike" "$change" 'volume a before its tar: worldsx/db 9 1.5' "$done_line"
backup_log "$work/unfinished" "$change" 'volume a before its tar: worlds 4096 1.5'

expect "a clean run logs no differing listing" "0 0 0 0" listing_audit "$work/clean" a
expect "a retry logs its entries, all of a held volume" "1 4 0 0" listing_audit "$work/retry" a
expect "an entry of another volume is not counted" "0 0 0 0" listing_audit "$work/retry" b
rule "a clean run follows the rule" holds "$work/clean"
rule "a retry whose entries are under worlds/ and .capture/ or are server.lock follows it" holds "$work/retry"
rule "a run failed on a differing listing twice follows it" holds "$work/twice"
rule "an entry under players/ on a held volume breaks it" refused "$work/outside"
rule "a differing listing with no entry breaks it" refused "$work/nowhere"
rule "a path that only begins like worlds breaks it" refused "$work/lookalike"
rule "a run that neither completed nor failed on a listing breaks it" refused "$work/unfinished"

cat >"$work/server.log" <<'EOF'
Command output | World "world": 99 loaded chunks, 4 ticking chunks, 0 entities. Time 0.1ms
[10:00:02.000] [Server thread/INFO]: [RiftalCapture] capture other held: 3 player files staged in 5.0ms, lease ends at 1
[10:00:03.000] [Server thread/INFO]: [RiftalCapture] capture r held: 500 player files staged in 40.5ms, lease ends at 9
Command output | Total memory: 100.10 MB.
Command output | World "world": 1,289 loaded chunks, 4 ticking chunks, 0 entities. Time 0.1ms
Command output | Total memory: 1,234.56 MB.
[10:00:04.250] [Server thread/INFO]: [RiftalCapture] capture r released, autosave on
Command output | World "world": 5 loaded chunks, 4 ticking chunks, 0 entities. Time 0.1ms
EOF
expect "the figures are the last sample inside the hold" "500 40.5 1290.5 1289 1234.56" cost_figures "$work/server.log" r
sed 's/| World/| \x1b[6mWorld/;s/Total memory: /Total memory: \x1b[31m/' "$work/server.log" >"$work/coloured.log"
expect "colour codes in the log are read past" "500 40.5 1290.5 1289 1234.56" cost_figures "$work/coloured.log" r
grep -v 'Total memory: 100.10' "$work/server.log" >"$work/no-sample.log"
grep -v '1,289 loaded' "$work/no-sample.log" >"$work/none.log"
expect "a sample before the held line is not counted" "500 40.5 1290.5 - 1234.56" cost_figures "$work/none.log" r
printf '[23:59:59.500] x: capture m held: 1 player files staged in 10ms, lease ends at 1\n[00:00:01.500] x: capture m released, autosave on\n' >"$work/midnight.log"
expect "a hold across midnight" "1 10 2010.0 - -" cost_figures "$work/midnight.log" m
expect "a request never held prints nothing" "" cost_figures "$work/server.log" absent

# $1 case, $2 wanted status (holds or refused), $3 a log.
session() {
  local what=$1 want=$2 status=holds
  held_inside_session "$3" r p3a || status=refused
  if [ "$status" = "$want" ]; then
    printf '  ok    %s\n' "$what"
  else
    printf '::error::%s: wanted %s, got %s\n' "$what" "$want" "$status"
    FAILURES=$((FAILURES + 1))
  fi
}

held_line='capture r held: 1 player files staged in 1ms, lease'
printf '[1] p3a joined the game\n[2] %s\n[3] p3a left the game\n' "$held_line" >"$work/inside.log"
printf '[1] p3a joined the game\n[2] p3a left the game\n[3] %s\n' "$held_line" >"$work/after.log"
printf '[1] %s\n[2] p3a joined the game\n[3] p3a left the game\n' "$held_line" >"$work/before.log"
printf '[1] p3a joined the game\n[2] %s\n' "$held_line" >"$work/stays.log"
printf '[1] p3a joined the game\n[2] p3a left the game\n[3] %s\n[4] p3a joined the game\n[5] p3a left the game\n' "$held_line" >"$work/earlier.log"
session "a hold between the join and the leave is inside the session" holds "$work/inside.log"
session "a hold after the leave is not" refused "$work/after.log"
session "a hold before the join is not" refused "$work/before.log"
session "a bot that never leaves is not counted" refused "$work/stays.log"
session "a hold between two sessions is not inside either" refused "$work/earlier.log"

[ "$FAILURES" -eq 0 ] || exit 1
printf 'capture-cost.sh reads every figure and refuses every broken log\n'
