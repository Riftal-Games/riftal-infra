#!/usr/bin/env bash
# What the bot-proofs harness prints from the logs a run leaves behind (ADR 040 item 5).
# Sourced by deploy/bot-proofs.sh and by bot-proofs-runner-logs-selftest.sh, which
# drives every function here from fixture logs.
#
# State is PRINTED, the ledger file print_runner appends to.

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
    print_runner "unprinted start $n pid $pid" "$log"
  done <"$file"
}
