#!/usr/bin/env bash
# What the bot-proofs harness decides its exit status from (ADR 024 item 3). Sourced
# by deploy/bot-proofs.sh, by the "$NODE" wrapper it writes, and by
# bot-proofs-finish-selftest.sh, which drives every function here from fixture hold
# logs and record files.
#
# State is read from LISTINGS, LISTINGS_CLEAN, HOLDS, RELEASED, HOLD_FAILURES,
# RUNNERS and RUNNERS_CLEAN, set by read_hold_log and read_records, and from FOUND,
# PASSES, FAILURES and EXPECTED_ASSERTIONS, set by the harness. PROC_ROOT stands in for
# /proc so the self-test can describe a process without starting one.
PROC_ROOT="${PROC_ROOT:-/proc}"

# Sets LOG_PATH to the regular file that fd 1 and fd 2 of this process both name and
# are one open file description of, else returns 1. It writes one FDCHECK line to
# fd 1 once both name that file, then reads both offsets: one description has moved
# both, two descriptions of one file (`>f 2>f`) have moved only fd 1.
shared_log() {
  local fd=$PROC_ROOT/$$ p1 p2
  LOG_PATH="$(readlink "$fd/fd/1")" || return 1
  [[ $LOG_PATH == /* && -f $LOG_PATH && $LOG_PATH == "$(readlink "$fd/fd/2")" ]] || return 1
  printf 'FDCHECK\n' || return 1
  p1="$(sed -n 's/^pos:[[:space:]]*//p' "$fd/fdinfo/1")" p2="$(sed -n 's/^pos:[[:space:]]*//p' "$fd/fdinfo/2")"
  [[ $p1 =~ ^[1-9][0-9]*$ && $p1 = "$p2" ]]
}

# $1 the probe script's path, $2 the record file, the rest the argument list of one
# "$NODE" start. A start is recorded, one line "node<TAB>pid<TAB>log", unless its
# first argument is exactly $1 or its whole argument list is exactly --version. Those
# two start no bot client; every other start is a possible one, so it is recorded
# whatever it runs. log is what shared_log finds, or - when it finds nothing.
record_node_start() {
  local probe=$1 file=$2
  shift 2
  if [ -n "$probe" ] && [ "$#" -ge 1 ] && [ "$1" = "$probe" ]; then return 0; fi
  if [ "$#" -eq 1 ] && [ "$1" = --version ]; then return 0; fi
  shared_log || LOG_PATH=-
  printf 'node\t%s\t%s\n' "$$" "$LOG_PATH" >>"$file"
}

# $1 a pid. True when the process is gone or a zombie. A state that cannot be read
# counts as running.
runner_exited() {
  local state
  [ -d "$PROC_ROOT/$1" ] || return 0
  state="$(sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "$PROC_ROOT/$1/status" 2>/dev/null)"
  [ "$state" = Z ] || [ "$state" = X ]
}

# $1 a runner's log. True when all of these hold, read from the log alone: exactly
# one SCENARIO line, with a PASS, FAIL or INCONCLUSIVE verdict and no "timed out"; the
# text after `SCENARIO <verdict> <name> |` is read only for that refusal, never to
# count a runner clean; exactly one PROBE DONE line giving H holds and the ports Ps;
# H PROBE HOLD lines; for each n in 1..H exactly one clean ROOT LISTING n line and
# one PROBE RELEASED n p open line naming the same port p, and no other ROOT LISTING
# or PROBE RELEASED line; every port in Ps held by one of those; every SOCKET LISTING
# head reading clean; no SOCKET LISTING head when H is 0.
runner_log_clean() {
  [[ $1 == /* && -f $1 ]] || return 1
  awk '
    /^SCENARIO / { sc++; if ($0 !~ /^SCENARIO (PASS|FAIL|INCONCLUSIVE) / || $0 ~ /timed out/) bad = 1 }
    /^PROBE DONE / { dn++; done = $0 }
    /^PROBE HOLD [0-9]+ / { holds++ }
    /^ROOT LISTING / { rl++; if ($0 ~ /^ROOT LISTING [0-9]+ clean \| held port [0-9]+ \|/) { split($0, f, " "); held[f[3]] = f[8] } }
    /^PROBE RELEASED / { rel++; if ($0 ~ /^PROBE RELEASED [0-9]+ [0-9]+ open$/) { opened[$3] = $4 } }
    /^SOCKET LISTING / { sk++; if ($0 !~ /^SOCKET LISTING [^|]* \| pid [0-9]+ \| live bots [0-9]+ \| clean \|/) bad = 1 }
    END {
      if (bad || sc != 1 || dn != 1 || done !~ /^PROBE DONE \{"holds":[0-9]+,"ports":\[([0-9]+(,[0-9]+)*)?\]\}$/) exit 1
      h = done; sub(/^PROBE DONE \{"holds":/, "", h); ports = h; sub(/,.*/, "", h); sub(/^[0-9]+,"ports":\[/, "", ports); sub(/\].*/, "", ports)
      h += 0
      if (holds + 0 != h || rl + 0 != h || rel + 0 != h || (h == 0 && sk > 0)) exit 1
      for (n = 1; n <= h; n++) { if (!(n in held) || !(n in opened) || held[n] != opened[n]) exit 1; known[held[n]] = 1 }
      np = split(ports, ps, ",")
      for (i = 1; i <= np; i++) if (!(ps[i] in known)) exit 1
    }' <"$1"
}

# $1 the record file, the rest the harness's own files. RUNNERS is the number of
# recorded starts, 1 when the file exists and cannot be read. RUNNERS_CLEAN is the
# number of those whose process has exited and whose log passes runner_log_clean,
# and is neither one of the harness's files nor named by another record.
read_records() {
  local kind file=$1 i j f n=0 pids=() logs=() pid log
  shift
  RUNNERS=0 RUNNERS_CLEAN=0
  [ -e "$file" ] || return 0
  [ -r "$file" ] || { RUNNERS=1; return 0; }
  while IFS=$'\t' read -r kind pid log || [ -n "$kind" ]; do
    pids[n]=$pid logs[n]=$log n=$((n + 1))
  done <"$file"
  RUNNERS=$n
  for ((i = 0; i < n; i++)); do
    [[ ${pids[i]} =~ ^[0-9]+$ ]] && runner_exited "${pids[i]}" && runner_log_clean "${logs[i]}" || continue
    for f; do [ "${logs[i]}" -ef "$f" ] && continue 2; done
    for ((j = 0; j < n; j++)); do [ "$j" -ne "$i" ] && [ "${logs[i]}" -ef "${logs[j]}" ] && continue 2; done
    RUNNERS_CLEAN=$((RUNNERS_CLEAN + 1))
  done
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
# printed; every recorded start of "$NODE" is a clean runner.
clean_finish() {
  [ "$FOUND" = 0 ] && [ "$LISTINGS" -ge 1 ] && [ "$LISTINGS" = "$LISTINGS_CLEAN" ] &&
    [ "$HOLDS" = "$RELEASED" ] && [ "$HOLD_FAILURES" = 0 ] && [ "$RUNNERS" = "$RUNNERS_CLEAN" ]
}

# $1 the body's own rc, before any mapping. Prints the exit status:
# 3 when FOUND is 1; else the rc, with 3 and 4 as 1, when it is not 0; else 1 when
# the assertions that ran differ from EXPECTED_ASSERTIONS or any failed; else 0. A
# status of 0 becomes 1 when a recorded runner is not clean. A status of 1 becomes 4
# only when the rc is 0 or 1 and clean_finish holds. The rc is 124 for a TERM, an INT,
# the deadline and the body's bare MySQL-wait `timeout`, 125 to 127 for a command that
# did not run, 128+n for a signal: none reaches 4.
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
  if [ "$status" = 0 ] && [ "$RUNNERS" != "$RUNNERS_CLEAN" ]; then
    printf '::error::%s of %s bot runners were judged clean\n' "$RUNNERS_CLEAN" "$RUNNERS" >&2
    status=1
  fi
  if [ "$status" = 1 ] && { [ "$rc" = 0 ] || [ "$rc" = 1 ]; } && clean_finish; then status=4; fi
  printf '%s\n' "$status"
}
