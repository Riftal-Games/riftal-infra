#!/usr/bin/env bash
# Sourced, not run, by ci-sweep-selftest.sh, whose reap needs every job to time
# out before its cutoff, and by job-timeouts-selftest.sh.

# Prints one line saying whether every job in the workflow at $1 times out in
# under $2 seconds, and why not, and returns non-zero when one does not. A job
# that calls a workflow in this checkout is held to the jobs of the file it
# calls, since GitHub accepts no timeout-minutes on a call and each called job
# defaults to 360 minutes. A call to any other repository is refused, because
# its jobs are not here to read.
job_timeouts_under() {
  _jt_jobs=0
  _jt_worst=0
  _jt_chain=""
  if _jt_check "$1" "$2"; then
    printf 'every one of %s job(s) run by %s times out within %s minutes, under %s\n' \
      "$_jt_jobs" "$1" "$_jt_worst" "$(($2 / 60))"
    return 0
  fi
  printf '%s\n' "$_jt_reason"
  return 1
}

# Prints one record per job under jobs: its key, then runs-on, uses or
# neither, then the job's timeout-minutes or the workflow it calls. A job is a
# key indented two spaces, and its own keys sit at four, so a step's
# timeout-minutes, deeper in, never stands in for its job's.
_jt_jobs_of() {
  awk '
    function flush() {
      if (name == "") return
      if (uses != "") print name "\tuses\t" uses
      else if (runs) print name "\truns-on\t" (timeout == "" ? "-" : timeout)
      else print name "\tneither\t-"
      name = ""
    }
    /^jobs:[ \t]*(#.*)?$/ { injobs = 1; next }
    injobs && /^[^ #]/ { flush(); injobs = 0 }
    !injobs { next }
    /^  [^ #]/ {
      flush()
      name = $1
      sub(/:.*/, "", name)
      runs = 0
      uses = ""
      timeout = ""
      next
    }
    /^    runs-on:/ { runs = 1 }
    /^    uses:/ { uses = $2; gsub(/["\047]/, "", uses) }
    /^    timeout-minutes:/ { timeout = $2 }
    END { flush() }' "$1"
}

# Sets _jt_reason and returns non-zero on the first job of $1 that does not
# time out in under $2 seconds, following calls. Adds the jobs that run to
# _jt_jobs and the longest timeout to _jt_worst. Reads its records through a
# process substitution, not a pipe, so those totals reach the caller.
_jt_check() {
  local workflow="$1" cutoff="$2" root called chain name kind value found=0
  if [ ! -r "$workflow" ]; then
    _jt_reason="cannot read $workflow to check every job times out"
    return 1
  fi
  # A local call names its file from the repository root, which for a real
  # workflow is two directories above it. A fixture outside any
  # .github/workflows resolves from its own directory.
  case "$workflow" in
    */.github/workflows/*) root="${workflow%/.github/workflows/*}" ;;
    *) root="$(dirname "$workflow")" ;;
  esac
  while IFS=$'\t' read -r name kind value; do
    found=1
    case "$kind" in
      neither)
        _jt_reason="$workflow: job $name has neither runs-on nor uses"
        return 1
        ;;
      uses)
        if ! [[ "$value" =~ ^\./\.github/workflows/[^/]+\.ya?ml$ ]]; then
          _jt_reason="$workflow: job $name uses $value, not a workflow in this checkout's .github/workflows, so its jobs cannot be read"
          return 1
        fi
        called="$root/${value#./}"
        if [[ $'\n'"$_jt_chain"$'\n' == *$'\n'"$called"$'\n'* ]] || [ "$called" = "$workflow" ]; then
          _jt_reason="$workflow: job $name calls $called, which is already in its own call chain"
          return 1
        fi
        chain="$_jt_chain"
        _jt_chain="$_jt_chain"$'\n'"$workflow"
        if ! _jt_check "$called" "$cutoff"; then
          _jt_reason="$workflow: job $name: $_jt_reason"
          return 1
        fi
        _jt_chain="$chain"
        ;;
      runs-on)
        if [ "$value" = - ]; then
          _jt_reason="$workflow: job $name has no job-level timeout-minutes"
          return 1
        elif ! [[ "$value" =~ ^[0-9]+$ ]]; then
          _jt_reason="$workflow: job $name has a timeout-minutes that is not a plain number"
          return 1
        fi
        # Shell arithmetic would read 023 as octal 19. Read as decimal it is 23,
        # and a string of the digits 0 to 7 is never smaller in decimal than in
        # octal, so whichever way the workflow's YAML is read, base 10 can only
        # refuse a timeout that would pass, never pass one that would not.
        value=$((10#$value))
        if [ $((value * 60)) -ge "$cutoff" ]; then
          _jt_reason="$workflow: job $name times out at $value minutes, not under $((cutoff / 60))"
          return 1
        fi
        _jt_jobs=$((_jt_jobs + 1))
        if [ "$value" -gt "$_jt_worst" ]; then
          _jt_worst="$value"
        fi
        ;;
    esac
  done < <(_jt_jobs_of "$workflow")
  if [ "$found" -eq 0 ]; then
    _jt_reason="$workflow: no job key indented two spaces under jobs"
    return 1
  fi
  return 0
}
