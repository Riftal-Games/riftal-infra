#!/usr/bin/env bash
# What the bot-proofs harness prints from the logs a run leaves behind (ADR 040 item 5).
# Sourced by deploy/bot-proofs.sh and by bot-proofs-runner-logs-selftest.sh, which
# drives every function here from fixture logs.
#
# State is PRINTED, the ledger file print_runner appends to, and LIVE, the file
# print_live_runner appends the runners that were still running at their first print
# to. runner_exited comes from bot-proofs-finish.sh, sourced before this file.

# $1 a directory, $2 a label. Prints every RakLib thread line of every instance log in
# the directory, each tagged with the log's name and the label: a.log, a2.log... for
# A, b1.log... for B, r.log for R.
raklib_lines() {
  local f
  for f in "$1"/a.log "$1"/a[0-9]*.log "$1"/b[0-9]*.log "$1"/r.log; do
    [ -e "$f" ] || continue
    { grep -F '[RakLib thread/' "$f" || true; } | sed "s/^/  ${f##*/} $2 | /"
  done
}

# $1 a tag, $2 a runner's log. Prints the whole log under the tag, then enters it in
# PRINTED so teardown does not print it again.
print_runner() {
  sed "s/^/  $1 | /" "$2"
  printf '%s\n' "$2" >>"${PRINTED:?}"
}

# $1 the record file of recorded starts, the rest the harness's own files, which are
# not runner logs. Prints, whole and tagged with its start's number and pid, the log
# of every recorded start that is a regular file and is not in PRINTED, once per log.
print_unprinted_runners() {
  local file=$1 kind pid log n=0 f
  shift
  [ -r "$file" ] || return 0
  while IFS=$'\t' read -r kind pid log || [ -n "$kind" ]; do
    n=$((n + 1))
    [[ $log == /* && -f $log ]] || continue
    for f; do [ "$log" -ef "$f" ] && continue 2; done
    if [ -r "${PRINTED:?}" ]; then
      while IFS= read -r f; do [ "$log" -ef "$f" ] && continue 2; done <"$PRINTED"
    fi
    if [[ $pid =~ ^[0-9]+$ ]] && ! runner_exited "$pid"; then
      print_live_runner "$n" "$pid" "$log"
    else
      print_runner "unprinted start $n pid $pid" "$log"
    fi
  done <"$file"
}

# $1 a start's number, $2 its pid, $3 its log, which the runner is still writing. Prints
# the complete lines the log holds now under a tag that says the runner is live, and
# records how many in LIVE so print_live_remainders prints from the next line on.
print_live_runner() {
  local lines
  lines=$(($(wc -l <"$3")))
  head -n "$lines" "$3" | sed "s/^/  unprinted start $1 pid $2 live | /"
  printf '%s\n' "$3" >>"${PRINTED:?}"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$lines" >>"${LIVE:?}"
}

# $1 seconds elapsed, $2 seconds at which the KILL lands, $3 seconds the work after
# the wait needs, $4 the longest wait. Prints the wait in seconds: what is left of the
# time before the KILL once $3 is kept back, at most $4 and never negative.
live_wait_bound() {
  local w=$(($2 - $3 - $1))
  [ "$w" -le "$4" ] || w=$4
  [ "$w" -ge 0 ] || w=0
  printf '%s\n' "$w"
}

# $1 the wait in seconds. Waits until every runner in LIVE has exited or the wait is
# over. It never signals a runner: node has no TERM handler, so a signal would lose
# the PROBE DONE line, the SOCKET LISTING heads and the SCENARIO line it has yet to
# print. Then prints, for each runner, the lines its log gained since
# print_live_runner, under the same start number, and for each that is still running
# one line saying its later output is not recorded.
print_live_remainders() {
  local deadline=$((SECONDS + $1)) n pid log lines pending gained
  [ -s "${LIVE:?}" ] || return 0
  while :; do
    pending=0
    while IFS=$'\t' read -r n pid log lines; do
      runner_exited "$pid" || pending=1
    done <"$LIVE"
    if [ "$pending" = 0 ] || [ "$SECONDS" -ge "$deadline" ]; then break; fi
    sleep 0.2
  done
  while IFS=$'\t' read -r n pid log lines; do
    if runner_exited "$pid"; then
      tail -n +$((lines + 1)) "$log" | sed "s/^/  unprinted start $n pid $pid continued | /"
    else
      gained=$(($(wc -l <"$log")))
      head -n "$gained" "$log" | tail -n +$((lines + 1)) | sed "s/^/  unprinted start $n pid $pid continued | /"
      printf '  unprinted start %s pid %s | still running after %ss, its later output is not recorded\n' "$n" "$pid" "$1"
    fi
  done <"$LIVE"
}
