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
net="riftal_smoke_sweep_net_${GITHUB_RUN_ID}_$$"
holder="riftal_smoke_sweep_holder_${GITHUB_RUN_ID}_$$"
own_vol="riftal_smoke_sweep_own_vol_${GITHUB_RUN_ID}_$$"
other_vol="riftal_smoke_sweep_other_vol_${GITHUB_RUN_ID}_$$"
reap_prefix="riftal_smoke_sweep_reaptest_${GITHUB_RUN_ID}_$$_"
reap_young="${reap_prefix}young"
reap_old="${reap_prefix}old"
reap_label="${reap_prefix}label"
reap_miss="riftal_smoke_sweep_reapmiss_${GITHUB_RUN_ID}_$$"
cleanup() {
  docker rm -v -f "$own" "$other" "$holder" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  docker volume rm "$own_vol" "$other_vol" "$reap_young" "$reap_old" "$reap_miss" \
    "$reap_label" >/dev/null 2>&1 || true
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

# The reap's three conditions run against volumes named for this run alone. A
# cutoff in the future would remove a concurrent run's volume under the real
# prefix, so the real prefix never sees one.
for vol in "$reap_young" "$reap_old" "$reap_miss"; do
  GITHUB_RUN_ID='' docker volume create --label riftal.ci.job=selftest-other-job "$vol" \
    >/dev/null || exit 1
done
docker volume create "$reap_label" >/dev/null || exit 1
reap_other_vols "$(($(date +%s) - 1200))" "$reap_prefix" || exit 1
kept="$(docker volume ls -q --filter "name=^${reap_young}\$")"
check "$([ "$kept" = "$reap_young" ] && echo ok)" "reap keeps a matching volume younger than the cutoff (got '$kept')"
reap_other_vols "$(($(date +%s) + 3600))" "$reap_prefix" || exit 1
gone="$(docker volume ls -q --filter "name=^${reap_old}\$")"
check "$([ -z "$gone" ] && echo ok)" "reap removes a matching volume older than the cutoff (got '$gone')"
kept="$(docker volume ls -q --filter "name=^${reap_miss}\$")"
check "$([ "$kept" = "$reap_miss" ] && echo ok)" "reap keeps the other job's volume under another name (got '$kept')"
kept="$(docker volume ls -q --filter "name=^${reap_label}\$")"
check "$([ "$kept" = "$reap_label" ] && echo ok)" "reap keeps a matching name under this job's label (got '$kept')"
docker volume rm "$reap_young" "$reap_miss" "$reap_label" >/dev/null 2>&1

# The other job's volume carries a label no sweep matches, so a cancel that
# kills this script before its EXIT trap leaves it for the next run on this
# engine to remove. The job times out at 10 minutes, so a volume older than 20
# belongs to a run that has ended, and a younger one may be a concurrent run's
# still waiting on its assertion.
reap_other_vols "$(($(date +%s) - 1200))" riftal_smoke_sweep_other_vol_ || exit 1

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
out="$(bash "$sweep")"
rc=$?
wait "$releaser"
printf '%s\n' "$out" | sed 's/^/  sweep | /'
check "$([ "$rc" -eq 0 ] && echo ok)" "sweep exits 0 once a held network is released (got $rc)"
held="$(docker network ls -q --filter "name=^${net}\$")"
check "$([ -z "$held" ] && echo ok)" "sweep removed this job's network after its first removal was refused"

# A label script that wraps its own shim leaves that shim exec'ing itself
# forever. Run against this job's own shim, it would hang this script's EXIT
# trap and the sweep step after it until the job timeout, so both runs go to a
# scratch RUNNER_TEMP and GITHUB_PATH, with that scratch shim first on PATH the
# way GITHUB_PATH puts the real one there. Every call is bounded, so a
# regression fails this check and leaves `docker` for the rest of the job alone.
sandbox="$(mktemp -d)"
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
rm -rf "$sandbox"
check "$([ "$rc" -eq 0 ] && echo ok)" "a shim written by a second label run answers within 20s (got $rc)"

[ "$failures" -eq 0 ] || exit 1
printf 'label shim and sweep proven on this engine\n'
