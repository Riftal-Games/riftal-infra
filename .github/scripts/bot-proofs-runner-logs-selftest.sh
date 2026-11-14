#!/usr/bin/env bash
# Proves bot-proofs-runner-logs.sh can fail (riftal-infra#1374). Fixture instance logs,
# runner logs and record files drive its functions, then each mutant of it must fail
# exactly the cases that guard the line it breaks. The harness is not run, no
# container starts.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/bot-proofs-runner-logs.sh"
FINISH="$DIR/bot-proofs-finish.sh"
EXPECTED_CASES=36

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 the file to source, $2 a scratch directory of its own. Prints one "  ok" or
# "FAILCASE" line per case, so a mutant that stops early shows as missing cases.
run_cases() { ( . "$FINISH" && . "$1" && cases "$2" ) </dev/null 2>/dev/null; }

cases() {
  local d=$1 i out out2 ledger rec bg t0 gone
  mkdir -p "$d/inst" "$d/empty" "$d/run" "$d/proc"
  PROC_ROOT="$d/proc"
  RK() { printf '[12:00:0%s] [RakLib thread/%s]: %s\n' "$1" "$2" "$3"; }
  { RK 1 INFO a-one; echo noise; RK 2 WARNING a-two; } >"$d/inst/a.log"
  RK 3 INFO a2-only >"$d/inst/a2.log"
  echo noise >"$d/inst/a3.log"
  { RK 4 INFO b1-only; echo noise; } >"$d/inst/b1.log"
  RK 5 ERROR b2-only >"$d/inst/b2.log"
  RK 6 INFO r-only >"$d/inst/r.log"
  RK 7 INFO decoy-only >"$d/inst/p10-bots.log"

  # $1 id, $2 wanted, $3 got
  is() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; else printf 'FAILCASE %s wanted "%s", got "%s"\n' "$1" "$2" "$3"; fi
  }

  out="$(raklib_lines "$d/inst" "after stop")"
  is raklib-a '2' "$(grep -c '^  a.log after stop | .*a-' <<<"$out")"
  is raklib-a-digit '1' "$(grep -c '^  a2.log after stop | .*a2-only' <<<"$out")"
  is raklib-b '2' "$(grep -c '^  b[12].log after stop | ' <<<"$out")"
  is raklib-r '1' "$(grep -c '^  r.log after stop | .*r-only' <<<"$out")"
  is raklib-decoy '0' "$(grep -c 'decoy' <<<"$out")"
  is raklib-no-noise '0' "$(grep -c 'noise' <<<"$out")"
  is raklib-total '6' "$(grep -c . <<<"$out")"
  is raklib-empty-dir '0:0' "$(raklib_lines "$d/empty" x | grep -c .):$(raklib_lines "$d/empty" x >/dev/null; echo $?)"

  PRINTED="$d/printed"
  : >"$PRINTED"
  printf '%s\n' one two >"$d/run/printed.log"
  printf '%s\n' three four >"$d/run/aborted.log"
  printf '%s\n' five >"$d/run/third.log"
  printf '%s\n' hold >"$d/hold.log"
  printf '%s\n' ainst >"$d/a.log"
  out="$(print_runner bots "$d/run/printed.log")"
  is print-tags-whole "  bots | one"$'\n'"  bots | two" "$out"
  is print-records "$d/run/printed.log" "$(cat "$PRINTED")"

  rec="$d/runners"
  {
    printf 'node\t11\t%s\n' "$d/run/printed.log"
    printf 'node\t12\t%s\n' "$d/run/aborted.log"
    printf 'node\t13\t%s\n' "$d/run/aborted.log"
    printf 'node\t14\t-\n'
    printf 'node\t15\t%s\n' "$d/run/missing.log"
    printf 'node\t16\t%s\n' "$d/hold.log"
    printf 'node\t17\t%s\n' "$d/a.log"
    printf 'node\t18\t%s\n' "$d/run/third.log"
  } >"$rec"
  out="$(print_unprinted_runners "$rec" "$d/hold.log" "$d/a.log")"
  is unprinted-output "  unprinted start 2 pid 12 | three"$'\n'"  unprinted start 2 pid 12 | four"$'\n'"  unprinted start 8 pid 18 | five" "$out"
  is unprinted-printed-skipped '0' "$(grep -c 'one\|two' <<<"$out")"
  is unprinted-whole '2' "$(grep -c 'three\|four' <<<"$out")"
  is unprinted-once '1' "$(grep -c 'three' <<<"$out")"
  is unprinted-tagged-with-start '0' "$(grep -vc '^  unprinted start [0-9]* pid [0-9]* | ' <<<"$out")"
  is unprinted-harness-files '0' "$(grep -c 'hold\|ainst' <<<"$out")"
  is unprinted-ledger "$d/run/printed.log|$d/run/aborted.log|$d/run/third.log" "$(paste -sd'|' "$PRINTED")"
  out="$(print_unprinted_runners "$rec" "$d/hold.log" "$d/a.log")"
  is unprinted-second-pass-empty '' "$out"

  rm -f "$PRINTED"
  out="$(print_unprinted_runners "$rec" "$d/hold.log" "$d/a.log" | grep -c .)"
  is unprinted-no-ledger '5' "$out"
  is unprinted-no-record '' "$(PRINTED="$d/p2" print_unprinted_runners "$d/absent" "$d/hold.log")"
  is unprinted-no-record-rc '0' "$(PRINTED="$d/p2" print_unprinted_runners "$d/absent" >/dev/null; echo $?)"
  ledger="$(grep -c . "$d/p2" 2>/dev/null || true)"
  is unprinted-no-record-writes-nothing '' "$ledger"

  # Pid 202 and 205 are running and exit during the wait, 203 is running throughout
  # and 204 has no process. 203 is let go after 8 s so a wait that ignores its bound
  # ends and reads as a failed case.
  mkdir -p "$d/proc/202" "$d/proc/203" "$d/proc/205"
  for i in 202 203 205; do printf 'State:\tS (sleeping)\n' >"$d/proc/$i/status"; done
  kill() { printf '%s\n' "$*" >>"$d/kills"; }
  printf '%s\n' x1 x2 >"$d/run/exited.log"
  printf '%s\n' d1 d2 >"$d/run/during.log"
  printf 's1\ns2-partial' >"$d/run/stuck.log"
  printf '%s\n' f1 >"$d/run/fast.log"
  {
    printf 'node\t204\t%s\n' "$d/run/exited.log"
    printf 'node\t202\t%s\n' "$d/run/during.log"
    printf 'node\t203\t%s\n' "$d/run/stuck.log"
  } >"$d/runners2"
  PRINTED="$d/printed2" LIVE="$d/live2"
  : >"$PRINTED"
  is no-live-returns '0:' "$(print_live_remainders 5 >/dev/null; echo "$?"):$(print_live_remainders 5)"
  out="$(print_unprinted_runners "$d/runners2")"
  is live-first-pass "  unprinted start 1 pid 204 | x1"$'\n'"  unprinted start 1 pid 204 | x2"$'\n'"  unprinted start 2 pid 202 live | d1"$'\n'"  unprinted start 2 pid 202 live | d2"$'\n'"  unprinted start 3 pid 203 live | s1" "$out"
  is live-recorded '2,1' "$(cut -f4 "$LIVE" | paste -sd, -)"
  ( sleep 8; printf 'State:\tZ\n' >"$d/proc/203/status" ) >/dev/null 2>&1 &
  (
    sleep 0.5
    printf 'd3\nPROBE DONE x\n' >>"$d/run/during.log"
    printf -- '-rest\ns3\n' >>"$d/run/stuck.log"
    printf 'State:\tZ (zombie)\n' >"$d/proc/202/status"
  ) >/dev/null 2>&1 &
  bg=$!
  t0=${EPOCHREALTIME/./}
  out2="$(print_live_remainders 2)"
  gone=$(((${EPOCHREALTIME/./} - t0) / 1000))
  wait "$bg"
  is remainder-exited-during-wait "  unprinted start 2 pid 202 continued | d3"$'\n'"  unprinted start 2 pid 202 continued | PROBE DONE x" "$(grep 'pid 202' <<<"$out2")"
  is remainder-whole-lines "  unprinted start 3 pid 203 continued | s2-partial-rest"$'\n'"  unprinted start 3 pid 203 continued | s3" "$(grep 'pid 203 continued' <<<"$out2")"
  is still-live-note "  unprinted start 3 pid 203 | still running after 2s, its later output is not recorded" "$(grep 'not recorded' <<<"$out2")"
  is no-line-twice '0' "$(printf '%s\n%s\n' "$out" "$out2" | sed 's/^ *unprinted start [0-9]* pid [0-9]* [a-z]* | //' | grep -v '^unprinted' | sort | uniq -d | grep -c .)"
  is exited-before-teardown-once '1' "$(printf '%s\n%s\n' "$out" "$out2" | grep -c 'x1')"
  is wait-bounded '1' "$([ "$gone" -ge 1000 ] && [ "$gone" -le 4000 ] && echo 1 || echo "${gone}ms")"
  is no-signal '' "$(cat "$d/kills" 2>/dev/null)"

  printf 'node\t205\t%s\n' "$d/run/fast.log" >"$d/runners3"
  PRINTED="$d/printed3" LIVE="$d/live3"
  : >"$PRINTED"
  print_unprinted_runners "$d/runners3" >/dev/null
  ( sleep 0.5; printf 'f2\n' >>"$d/run/fast.log"; printf 'State:\tX\n' >"$d/proc/205/status" ) >/dev/null 2>&1 &
  bg=$!
  t0=${EPOCHREALTIME/./}
  out2="$(print_live_remainders 20)"
  gone=$(((${EPOCHREALTIME/./} - t0) / 1000))
  wait "$bg"
  is wait-ends-when-runners-exit "  unprinted start 1 pid 205 continued | f2:1" "$out2:$([ "$gone" -le 5000 ] && echo 1 || echo "${gone}ms")"

  is wait-bound-capped '30' "$(live_wait_bound 10 1620 60 30)"
  is wait-bound-shrinks '20' "$(live_wait_bound 1540 1620 60 30)"
  is wait-bound-floored '0' "$(live_wait_bound 1590 1620 60 30)"
}

good="$work/good"
mkdir -p "$good"
want_ids() { sed -n 's/^FAILCASE \([^ ]*\) .*/\1/p' | sort | tr '\n' ' '; }

out="$(run_cases "$LIB" "$good")"
cases_run="$(grep -cE '^(  ok    |FAILCASE )' <<<"$out")"
FAILURES=0 PASSES=0
if grep -q '^FAILCASE' <<<"$out" || [ "$cases_run" -ne "$EXPECTED_CASES" ]; then
  printf '%s\n' "$out"
  printf '::error::the unmutated library ran %s of %s cases and failed some\n' "$cases_run" "$EXPECTED_CASES"
  exit 1
fi
printf '  ok    %s cases pass on the library\n' "$cases_run"

src="$(cat "$LIB")"
# $1 a name, $2 the text to replace, $3 its replacement, $4 the space-separated case
# ids the mutant must fail, and no others.
mutant() {
  local file="$work/mutant.$1.sh" mutated="${src/"$2"/"$3"}" got
  if [ "$mutated" = "$src" ]; then
    printf '::error::mutant %s did not apply\n' "$1"; FAILURES=$((FAILURES + 1)); return
  fi
  printf '%s\n' "$mutated" >"$file"
  got="$(run_cases "$file" "$work/m.$1" | want_ids)"
  want="$(tr ' ' '\n' <<<"$4" | sort | tr '\n' ' ')"
  if [ "${got% }" = "${want% }" ]; then
    printf '  ok    mutant %s fails: %s\n' "$1" "$4"; PASSES=$((PASSES + 1))
  else
    printf '::error::mutant %s failed "%s", wanted "%s"\n' "$1" "${got% }" "${want% }"; FAILURES=$((FAILURES + 1))
  fi
}

mutant a-glob-dropped '"$1"/a.log ' '' "raklib-a raklib-total"
mutant a-digit-glob-dropped '"$1"/a[0-9]*.log ' '' "raklib-a-digit raklib-total"
mutant b-glob-dropped '"$1"/b[0-9]*.log ' '' "raklib-b raklib-total"
mutant r-glob-dropped ' "$1"/r.log' '' "raklib-r raklib-total"
mutant every-log-read '"$1"/a.log "$1"/a[0-9]*.log "$1"/b[0-9]*.log "$1"/r.log' '"$1"/*.log' "raklib-decoy raklib-total"
mutant non-matching-lines-printed "grep -F '[RakLib thread/' \"\$f\"" 'cat "$f"' "raklib-b raklib-no-noise raklib-total"
mutant untagged-by-log '${f##*/} $2 | ' '$2 | ' "raklib-a raklib-a-digit raklib-b raklib-r"
mutant print-not-recorded 'printf '"'"'%s\n'"'"' "$2" >>"${PRINTED:?}"' ':' "print-records unprinted-printed-skipped unprinted-once unprinted-output unprinted-ledger unprinted-second-pass-empty unprinted-no-ledger unprinted-whole"
mutant printed-ignored 'while IFS= read -r f; do [ "$log" -ef "$f" ] && continue 2; done <"$PRINTED"' 'false' "unprinted-printed-skipped unprinted-output unprinted-once unprinted-ledger unprinted-whole unprinted-second-pass-empty unprinted-no-ledger"
mutant harness-files-printed 'for f; do [ "$log" -ef "$f" ] && continue 2; done' ':' "unprinted-harness-files unprinted-output unprinted-ledger unprinted-no-ledger"
mutant non-files-printed '[[ $log == /* && -f $log ]] || continue' ':' "unprinted-harness-files unprinted-ledger unprinted-no-ledger unprinted-output unprinted-second-pass-empty"
mutant start-number-fixed 'n=$((n + 1))' 'n=1' "unprinted-output live-first-pass remainder-exited-during-wait remainder-whole-lines still-live-note"
mutant unprinted-untagged 'print_runner "unprinted start $n pid $pid" "$log"' 'print_runner "bots" "$log"' "unprinted-output unprinted-tagged-with-start live-first-pass"
mutant log-truncated 'sed "s/^/  $1 | /" "$2"' 'sed -n "1s/^/  $1 | /p" "$2"' "print-tags-whole unprinted-output unprinted-whole unprinted-no-ledger live-first-pass"
mutant live-runner-not-detected 'if [[ $pid =~ ^[0-9]+$ ]] && ! runner_exited "$pid"; then' 'if false; then' "live-first-pass live-recorded remainder-exited-during-wait remainder-whole-lines still-live-note wait-bounded wait-ends-when-runners-exit"
mutant live-tag-dropped 'pid $2 live | ' 'pid $2 | ' "live-first-pass"
mutant live-partial-line-printed 'head -n "$lines" "$3" |' 'cat "$3" |' "live-first-pass"
mutant live-lines-not-recorded '"$1" "$2" "$3" "$lines" >>"${LIVE:?}"' '"$1" "$2" "$3" 0 >>"${LIVE:?}"' "live-recorded no-line-twice remainder-exited-during-wait remainder-whole-lines wait-ends-when-runners-exit"
mutant wait-skipped 'sleep 0.2' 'break' "remainder-exited-during-wait remainder-whole-lines still-live-note wait-ends-when-runners-exit wait-bounded"
mutant wait-ignores-its-bound 'if [ "$pending" = 0 ] || [ "$SECONDS" -ge "$deadline" ]; then break; fi' 'if [ "$pending" = 0 ]; then break; fi' "still-live-note wait-bounded"
mutant wait-always-full 'if [ "$pending" = 0 ] || [ "$SECONDS" -ge "$deadline" ]; then break; fi' 'if [ "$SECONDS" -ge "$deadline" ]; then break; fi' "wait-ends-when-runners-exit"
mutant remainder-from-first-line 'tail -n +$((lines + 1)) "$log" |' 'tail -n +1 "$log" |' "no-line-twice remainder-exited-during-wait wait-ends-when-runners-exit"
mutant live-remainder-from-first-line 'head -n "$gained" "$log" | tail -n +$((lines + 1))' 'head -n "$gained" "$log"' "no-line-twice remainder-whole-lines"
mutant exited-treated-as-live 'if runner_exited "$pid"; then
      tail' 'if false; then
      tail' "remainder-exited-during-wait still-live-note wait-ends-when-runners-exit"
mutant still-running-not-named "      printf '  unprinted start %s pid %s | still running after" "      : '  unprinted start %s pid %s | still running after" "still-live-note"
mutant runner-signalled 'gained=$(($(wc -l <"$log")))' 'kill "$pid"; gained=$(($(wc -l <"$log")))' "no-signal"
mutant bound-cap-dropped '[ "$w" -le "$4" ] || w=$4' ':' "wait-bound-capped"
mutant bound-floor-dropped '[ "$w" -ge 0 ] || w=0' ':' "wait-bound-floored"
mutant bound-reserve-dropped 'local w=$(($2 - $3 - $1))' 'local w=$(($2 - $1))' "wait-bound-floored wait-bound-shrinks"

if [ "$FAILURES" -ne 0 ]; then
  printf '%s mutant(s) not caught for the reason expected\n' "$FAILURES"
  exit 1
fi
printf 'bot-proofs-runner-logs.sh refuses every mutant for its own reason (%s cases, %s mutants)\n' "$EXPECTED_CASES" "$PASSES"
