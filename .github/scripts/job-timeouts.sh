#!/usr/bin/env bash
# Sourced, not run, by ci-sweep-selftest.sh, whose reap needs every job to time
# out before its cutoff, and by job-timeouts-selftest.sh.

# Prints one line saying whether every job in the workflow at $1 times out in
# under $2 seconds, and why not, and returns non-zero when one does not. A job
# is a runs-on line indented four spaces, and its timeout-minutes sits at that
# same indent, so a step's, deeper in, never stands in for its job's.
job_timeouts_under() {
  local workflow="$1" cutoff="$2" jobs limited worst bad
  if [ ! -r "$workflow" ]; then
    printf 'cannot read %s to check every job times out\n' "$workflow"
    return 1
  fi
  read -r jobs limited worst bad < <(awk '
    /^    runs-on:/ { jobs++ }
    /^    timeout-minutes:/ {
      limited++
      if ($2 !~ /^[0-9]+$/) bad++
      else if ($2 + 0 > worst) worst = $2 + 0
    }
    END { print jobs + 0, limited + 0, worst + 0, bad + 0 }' "$workflow")
  if [ "${jobs:-0}" -eq 0 ]; then
    printf '%s: no job with a runs-on line\n' "$workflow"
  elif [ "$limited" -ne "$jobs" ]; then
    printf '%s: %s job(s), %s with a job-level timeout-minutes\n' "$workflow" "$jobs" "$limited"
  elif [ "$bad" -ne 0 ]; then
    printf '%s: %s job-level timeout-minutes not a plain number\n' "$workflow" "$bad"
  elif [ $((worst * 60)) -ge "$cutoff" ]; then
    printf '%s: longest job timeout is %s minutes, not under %s\n' "$workflow" "$worst" \
      "$((cutoff / 60))"
  else
    printf 'every one of %s job(s) in %s times out within %s minutes, under %s\n' \
      "$jobs" "$workflow" "$worst" "$((cutoff / 60))"
    return 0
  fi
  return 1
}
