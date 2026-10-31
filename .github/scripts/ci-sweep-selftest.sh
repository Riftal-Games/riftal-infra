#!/usr/bin/env bash
# Proves the label shim and the sweep on this runner's engine. A shim that
# never took effect, and a sweep that matched nothing, would each print the
# same clean line as a sweep that removed a real leak. Runs after the label
# step, so `docker` here resolves to the shim exactly as every self-test does.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sweep="$dir/ci-container-sweep.sh"
want="${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}-${GITHUB_JOB:-job}"
own="riftal_smoke_sweep_own_${GITHUB_RUN_ID}_$$"
other="riftal_smoke_sweep_other_${GITHUB_RUN_ID}_$$"
failures=0

# A sleep as PID 1 ignores SIGTERM, which would hold the sweep's stop for its
# full 60 seconds. The first argument is the container's lifetime in seconds: a
# cancel kills this script before its EXIT trap, and the container then outlives
# it by whatever is left of that lifetime.
start() {
  life="$1"
  shift
  docker run -d --rm -m 1g --cpus 1 "$@" php:8.3-cli-alpine \
    sh -c 'trap "exit 0" TERM; sleep "$1" & wait' sh "$life" >/dev/null
}
check() {
  if [ "$1" = ok ]; then
    printf '  ok    %s\n' "$2"
  else
    printf '::error::%s\n' "$2"
    failures=$((failures + 1))
  fi
}

# The reap below takes a volume older than reap_after seconds to be left by a
# run that has ended, which holds only while every job in this workflow times
# out sooner. A job with no timeout-minutes runs for 6 hours.
reap_after=2100
# shellcheck source=job-timeouts.sh
. "$dir/job-timeouts.sh"
if verdict="$(job_timeouts_under "${dir%/scripts}/workflows/ci.yml" "$reap_after")"; then
  check ok "$verdict, the reap's cutoff"
else
  check fail "$verdict; every job needs a job-level timeout-minutes under the reap's cutoff"
  exit 1
fi

net="riftal_smoke_sweep_net_${GITHUB_RUN_ID}_$$"
holder="riftal_smoke_sweep_holder_${GITHUB_RUN_ID}_$$"
late="riftal_smoke_sweep_late_${GITHUB_RUN_ID}_$$"
own_vol="riftal_smoke_sweep_own_vol_${GITHUB_RUN_ID}_$$"
other_vol="riftal_smoke_sweep_other_vol_${GITHUB_RUN_ID}_$$"
own_img="riftal_smoke_sweep_own_img_${GITHUB_RUN_ID}_$$"
other_img="riftal_smoke_sweep_other_img_${GITHUB_RUN_ID}_$$"
reap_prefix="riftal_smoke_sweep_reaptest_${GITHUB_RUN_ID}_$$_"
reap_young="${reap_prefix}young"
reap_old="${reap_prefix}old"
reap_label="${reap_prefix}label"
reap_miss="riftal_smoke_sweep_reapmiss_${GITHUB_RUN_ID}_$$"
sandbox=
cleanup() {
  [ -z "$sandbox" ] || rm -rf "$sandbox"
  docker rm -v -f "$own" "$other" "$holder" "$late" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  docker volume rm "$own_vol" "$other_vol" "$reap_young" "$reap_old" "$reap_miss" \
    "$reap_label" >/dev/null 2>&1 || true
  docker image rm "$own_img" "$other_img" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Removes every volume labelled as the other job's whose name starts with the
# second argument and whose creation time is before the first, in epoch seconds.
reap_other_vols() {
  local before="$1" prefix="$2" stale vol created epoch left
  if ! stale="$(docker volume ls -q --filter label=riftal.ci.job=selftest-other-job)"; then
    check fail "could not list the other job's volumes"
    return 1
  fi
  for vol in $stale; do
    case "$vol" in
      "$prefix"*) ;;
      *) continue ;;
    esac
    # A volume removed after the list, by its own run or another's, fails
    # inspect and is skipped.
    created="$(docker volume inspect -f '{{.CreatedAt}}' "$vol" 2>/dev/null)" || continue
    if ! epoch="$(date -d "$created" +%s)"; then
      check fail "unreadable creation time '$created' on $vol"
      continue
    fi
    [ "$epoch" -lt "$before" ] || continue
    docker volume rm "$vol" >/dev/null 2>&1
    left="$(docker volume ls -q --filter "name=^${vol}\$")"
    if [ -z "$left" ]; then
      check ok "removed $vol, left by a cancelled run"
    else
      check fail "could not remove $vol, left by a cancelled run; remove it by hand with: docker volume rm $vol"
    fi
  done
}

# The other job's volumes, both the reap's test volumes below and the one the
# sweep must leave alone, carry a label no sweep matches, so a cancel that kills
# this script before its EXIT trap leaves them for the next run on this engine
# to remove. Every job times out before reap_after, as checked above, so an
# older volume belongs to a run that has ended, and a younger one may be a
# concurrent run's still waiting on its assertion.
reap_other_vols "$(($(date +%s) - reap_after))" riftal_smoke_sweep_other_vol_ || exit 1
reap_other_vols "$(($(date +%s) - reap_after))" riftal_smoke_sweep_reap || exit 1

# The reap's three conditions run against volumes named for this run alone. A
# cutoff in the future would remove a concurrent run's volume under the real
# prefix, so the real prefix never sees one.
for vol in "$reap_young" "$reap_old" "$reap_miss"; do
  GITHUB_RUN_ID='' docker volume create --label riftal.ci.job=selftest-other-job "$vol" \
    >/dev/null || exit 1
done
docker volume create "$reap_label" >/dev/null || exit 1
reap_other_vols "$(($(date +%s) - reap_after))" "$reap_prefix" || exit 1
kept="$(docker volume ls -q --filter "name=^${reap_young}\$")"
check "$([ "$kept" = "$reap_young" ] && echo ok)" "reap keeps a matching volume younger than the cutoff (got '$kept')"
reap_other_vols "$(($(date +%s) + 3600))" "$reap_prefix" || exit 1
gone="$(docker volume ls -q --filter "name=^${reap_old}\$")"
check "$([ -z "$gone" ] && echo ok)" "reap removes a matching volume older than the cutoff (got '$gone')"
kept="$(docker volume ls -q --filter "name=^${reap_miss}\$")"
check "$([ "$kept" = "$reap_miss" ] && echo ok)" "reap keeps the other job's volume under another name (got '$kept')"
kept="$(docker volume ls -q --filter "name=^${reap_label}\$")"
check "$([ "$kept" = "$reap_label" ] && echo ok)" "reap keeps a matching name under this job's label (got '$kept')"
docker volume rm "$reap_miss" "$reap_label" >/dev/null 2>&1

if DOCKER_HOST=unix:///nonexistent.sock bash "$sweep" >/dev/null 2>&1; then
  check fail 'sweep exited 0 with no reachable daemon'
else
  check ok 'sweep fails when the daemon is unreachable'
fi

# 60 seconds outlasts the first sweep below, which "$other" must survive.
start 60 --name "$own" || exit 1
got="$(docker inspect -f '{{index .Config.Labels "riftal.ci.job"}}' "$own")"
check "$([ "$got" = "$want" ] && echo ok)" "shim labels a run with riftal.ci.job=$want (got '$got')"

# The shim passes through unlabelled without GITHUB_RUN_ID, so the only label
# this container carries is the other job's.
GITHUB_RUN_ID='' start 60 --name "$other" --label riftal.ci.job=selftest-other-job || exit 1

docker volume create "$own_vol" >/dev/null || exit 1
got="$(docker volume inspect -f '{{index .Labels "riftal.ci.job"}}' "$own_vol")"
check "$([ "$got" = "$want" ] && echo ok)" "shim labels a volume create with riftal.ci.job=$want (got '$got')"
GITHUB_RUN_ID='' docker volume create --label riftal.ci.job=selftest-other-job "$other_vol" \
  >/dev/null || exit 1

# The shim does not stamp docker build, so the label is passed as the harness does.
printf 'FROM php:8.3-cli-alpine\n' | docker build -q --label "riftal.ci.job=$want" -t "$own_img" - >/dev/null || exit 1
printf 'FROM php:8.3-cli-alpine\n' | docker build -q --label riftal.ci.job=selftest-other-job -t "$other_img" - >/dev/null || exit 1

out="$(bash "$sweep")"
rc=$?
printf '%s\n' "$out" | sed 's/^/  sweep | /'
check "$([ "$rc" -eq 0 ] && echo ok)" "sweep exits 0 (got $rc)"
listed="$(printf '%s\n' "$out" | sed -n '/^containers left by this job:$/,$p' | grep -c "^$own ")"
check "$([ "$listed" -eq 1 ] && echo ok)" "sweep names $own under 'containers left by this job:'"
gone="$(docker ps -aq --filter "name=^/${own}\$")"
check "$([ -z "$gone" ] && echo ok)" "sweep removed this job's container"
running="$(docker inspect -f '{{.State.Running}}' "$other" 2>/dev/null)"
check "$([ "$running" = true ] && echo ok)" "another job's container is still running (got '$running')"
listed="$(printf '%s\n' "$out" | sed -n '/^volumes left by this job:$/,$p' | grep -cx "$own_vol")"
check "$([ "$listed" -eq 1 ] && echo ok)" "sweep names $own_vol under 'volumes left by this job:'"
gone="$(docker volume ls -q --filter "name=^${own_vol}\$")"
check "$([ -z "$gone" ] && echo ok)" "sweep removed this job's volume"
kept="$(docker volume ls -q --filter "name=^${other_vol}\$")"
check "$([ "$kept" = "$other_vol" ] && echo ok)" "another job's volume survives the sweep (got '$kept')"
gone="$(docker images -q "$own_img")"
check "$([ -z "$gone" ] && echo ok)" "sweep removed this job's image"
kept="$(docker images -q "$other_img")"
check "$([ -n "$kept" ] && echo ok)" "another job's image survives the sweep"

# A container outside this job's label holds this job's network for its first
# seconds, so the sweep's first removal of it is refused, the way a --rm
# container still being removed refuses it. Only a sweep that retries the
# network inside its wait loop finishes clean.
#
# The holder is outside the label, so after a cancel the job's own sweep cannot
# stop it and only its lifetime frees the network. 20 seconds ends it inside
# that sweep's 30-second network window, and still leaves 15 seconds past the
# release below for a slow engine to start the stop.
docker network create "$net" >/dev/null || exit 1
GITHUB_RUN_ID='' start 20 --name "$holder" --network "$net" \
  --label riftal.ci.job=selftest-other-job || exit 1
(sleep 5; docker stop -t 10 "$holder" >/dev/null 2>&1) &
releaser=$!
# The daemon creating a container for a stopped client after the sweep's first
# listing: it is not in that listing, and the held network keeps the sweep in
# its wait loop long enough to see it later.
(sleep 2; docker create --rm -m 1g --cpus 1 --name "$late" php:8.3-cli-alpine true >/dev/null 2>&1) &
creator=$!
out="$(bash "$sweep")"
rc=$?
wait "$releaser" "$creator"
printf '%s\n' "$out" | sed 's/^/  sweep | /'
check "$([ "$rc" -eq 0 ] && echo ok)" "sweep exits 0 once a held network is released (got $rc)"
held="$(docker network ls -q --filter "name=^${net}\$")"
check "$([ -z "$held" ] && echo ok)" "sweep removed this job's network after its first removal was refused"
gone="$(docker ps -aq --filter "name=^/${late}\$")"
check "$([ -z "$gone" ] && echo ok)" "sweep removed a container created after its first listing"

# A docker client left running by a cancelled step is stood in for by a script
# named docker, which is all the sweep reads of a process: its name and the job
# it was started in. The sweep must stop this job's and leave alone the ones
# started under another run id, another attempt of this run, and another job
# of this run.
stray_dir="$(mktemp -d)" || exit 1
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$stray_dir/docker"
chmod 0755 "$stray_dir/docker"
"$stray_dir/docker" &
stray_own=$!
GITHUB_RUN_ID="${GITHUB_RUN_ID}0" "$stray_dir/docker" &
stray_other=$!
GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT}0" "$stray_dir/docker" &
stray_attempt=$!
GITHUB_JOB="${GITHUB_JOB:-job}0" "$stray_dir/docker" &
stray_job=$!
out="$(bash "$sweep")"
rc=$?
printf '%s\n' "$out" | sed 's/^/  sweep | /'
state_of() { ps -o stat= -p "$1" 2>/dev/null | cut -c1 | tr -d ' '; }
own_state="$(state_of "$stray_own")"
other_state="$(state_of "$stray_other")"
attempt_state="$(state_of "$stray_attempt")"
job_state="$(state_of "$stray_job")"
kill "$stray_other" "$stray_attempt" "$stray_job" "$stray_own" 2>/dev/null
wait "$stray_own" "$stray_other" "$stray_attempt" "$stray_job" 2>/dev/null
rm -rf "$stray_dir"
check "$([ "$rc" -eq 0 ] && echo ok)" "sweep exits 0 with a stray docker client to stop (got $rc)"
check "$([ -z "$own_state" ] || [ "$own_state" = Z ] && echo ok)" "sweep stopped this job's stray docker client (state '$own_state')"
check "$([ -n "$other_state" ] && [ "$other_state" != Z ] && echo ok)" "sweep left another job's docker client running (state '$other_state')"
check "$([ -n "$attempt_state" ] && [ "$attempt_state" != Z ] && echo ok)" "sweep left another attempt's docker client running (state '$attempt_state')"
check "$([ -n "$job_state" ] && [ "$job_state" != Z ] && echo ok)" "sweep left another job's docker client of this run running (state '$job_state')"
stopped="$(printf '%s\n' "$out" | grep -c '^stopped a docker client left running by an earlier step: pid ')"
check "$([ "$stopped" -eq 1 ] && echo ok)" "sweep reports stopping exactly one stray client (got $stopped)"

# A label script that wraps its own shim leaves that shim exec'ing itself
# forever. Run against this job's own shim, it would hang this script's EXIT
# trap and the sweep step after it until the job timeout, so both runs go to a
# scratch RUNNER_TEMP and GITHUB_PATH, with that scratch shim first on PATH the
# way GITHUB_PATH puts the real one there. Every call is bounded, so a
# regression fails this check and leaves `docker` for the rest of the job alone.
# Without this, a full or missing temp directory reads as three label-script
# failures against a shim path at the filesystem root.
if ! sandbox="$(mktemp -d)"; then
  check fail "mktemp -d could not make the label script's sandbox under ${TMPDIR:-/tmp}"
  exit 1
fi
shim="$sandbox/riftal-docker-label"
if RUNNER_TEMP="$sandbox" GITHUB_PATH="$sandbox/path" \
  timeout 20 bash "$dir/ci-docker-label.sh" >/dev/null &&
  PATH="$shim:$PATH" RUNNER_TEMP="$sandbox" GITHUB_PATH="$sandbox/path" \
    timeout 20 bash "$dir/ci-docker-label.sh" >/dev/null; then
  check ok 'label script runs a second time in one job'
else
  check fail 'label script failed on a second run in one job'
fi
timeout 20 "$shim/docker" version --format '{{.Server.Version}}' >/dev/null 2>&1
rc=$?
check "$([ "$rc" -eq 0 ] && echo ok)" "a shim written by a second label run answers within 20s (got $rc)"

# The runner's coreutils share a directory with the real docker, so this PATH
# holds the shim alone. The label script reaches its refusal on builtins only.
# With no shim there, it would refuse for want of any docker at all and pass
# without ever skipping its own shim.
if [ ! -x "$shim/docker" ]; then
  check fail "no executable shim at $shim/docker for the shim-only refusal check to skip"
else
  err="$(timeout 20 env PATH="$shim" RUNNER_TEMP="$sandbox" GITHUB_PATH="$sandbox/path" \
    "$BASH" "$dir/ci-docker-label.sh" 2>&1 >/dev/null)"
  rc=$?
  line="::error::no docker on PATH outside $shim"
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$err" = "$line" ]; then
    check ok 'label script refuses when only its own shim is on PATH'
  else
    # An annotation ends at the first newline, so every line of err goes on one.
    shown="${err//::error::/}"
    shown="${shown//$'\n'/ | }"
    check fail "label script with only its shim on PATH: want a non-zero exit and the no-docker error, got exit $rc and '$shown'"
  fi
fi

[ "$failures" -eq 0 ] || exit 1
printf 'label shim and sweep proven on this engine\n'
