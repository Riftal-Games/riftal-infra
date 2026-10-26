#!/usr/bin/env bash
# What the bot-proofs harness decides its exit status from (ADR 024 item 3). Sourced
# by deploy/bot-proofs.sh, by the "$NODE" wrapper it writes, and by
# bot-proofs-finish-selftest.sh, which drives every function here from fixture hold
# logs and record files.
#
# State is read from LISTINGS, LISTINGS_CLEAN, HOLDS, RELEASED, HOLD_FAILURES and
# RUNNERS, set by read_hold_log and read_records, and from FOUND, PASSES, FAILURES
# and EXPECTED_ASSERTIONS, set by the harness.

# $1 the probe script's path, $2 the record file, the rest the argument list of one
# "$NODE" start. A start is recorded, one line, unless its first argument is exactly
# $1 or its whole argument list is exactly --version. Those two start no bot client;
# every other start is a possible one, so it is recorded whatever it runs.
record_node_start() {
  local probe=$1 file=$2
  shift 2
  if [ -n "$probe" ] && [ "$#" -ge 1 ] && [ "$1" = "$probe" ]; then return 0; fi
  if [ "$#" -eq 1 ] && [ "$1" = --version ]; then return 0; fi
  printf 'node %s\n' "${1-}" >>"$file"
}

# $1 the record file. RUNNERS is the number of recorded starts: 1 when the file
# exists and cannot be counted, 0 when no start was recorded.
read_records() {
  RUNNERS=0
  [ -e "$1" ] || return 0
  RUNNERS="$(grep -c '' "$1" || true)"
  [[ $RUNNERS =~ ^[0-9]+$ ]] || RUNNERS=1
}

# $1 the hold's own output, read before teardown removes it. A log that is missing
# counts nothing, so clean_finish refuses.
read_hold_log() {
  LISTINGS=0 LISTINGS_CLEAN=0 HOLDS=0 RELEASED=0 HOLD_FAILURES=0
  [ -r "$1" ] || return 0
  LISTINGS="$(grep -cE '^ROOT LISTING [0-9]+ ' "$1" || true)"
  LISTINGS_CLEAN="$(grep -cE '^ROOT LISTING [0-9]+ clean \|' "$1" || true)"
  HOLDS="$(grep -cE '^probed [0-9]+$' "$1" || true)"
  RELEASED="$(grep -cE '^PROBE RELEASED [0-9]+ [0-9]+ open$' "$1" || true)"
  HOLD_FAILURES="$(grep -cE '^HOLD FAILURE ' "$1" || true)"
}

# True when all of these hold: FOUND is 0; at least one listing was taken and every
# one was judged clean; every hold was released open; no HOLD FAILURE line was
# printed; no start of "$NODE" was recorded.
clean_finish() {
  [ "$FOUND" = 0 ] && [ "$LISTINGS" -ge 1 ] && [ "$LISTINGS" = "$LISTINGS_CLEAN" ] &&
    [ "$HOLDS" = "$RELEASED" ] && [ "$HOLD_FAILURES" = 0 ] && [ "$RUNNERS" = 0 ]
}

# $1 the body's own rc, before any mapping. Prints the exit status:
# 3 when FOUND is 1; else the rc, with 3 and 4 as 1, when it is not 0; else 1 when
# the assertions that ran differ from EXPECTED_ASSERTIONS or any failed; else 0.
# A status of 1 becomes 4 only when the rc is 0 or 1 and clean_finish holds. The rc
# is 124 for a TERM, an INT, the deadline and the body's bare MySQL-wait `timeout`,
# 125 to 127 for a command that did not run, 128+n for a signal: none reaches 4.
finish_status() {
  local rc=$1 ran=$((PASSES + FAILURES)) status=0
  if [ "$FOUND" = 1 ]; then
    status=3
  elif [ "$rc" -ne 0 ]; then
    status=$((rc == 3 || rc == 4 ? 1 : rc))
  elif [ "$ran" -ne "$EXPECTED_ASSERTIONS" ] || [ "$FAILURES" -ne 0 ]; then
    printf '::error::%s of %s assertions ran and %s failed\n' "$ran" "$EXPECTED_ASSERTIONS" "$FAILURES" >&2
    status=1
  fi
  if [ "$status" = 1 ] && { [ "$rc" = 0 ] || [ "$rc" = 1 ]; } && clean_finish; then status=4; fi
  printf '%s\n' "$status"
}
