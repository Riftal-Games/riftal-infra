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
cleanup() {
  docker rm -v -f "$own" "$other" "$holder" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

# Last on purpose: a label script that wraps its own shim leaves `docker`
# exec'ing itself forever, and every check above would hang on it rather than
# fail. Its GITHUB_PATH line goes to a scratch file, since the shim's directory
# is already on this job's PATH.
scratch_path="$(mktemp)"
if GITHUB_PATH="$scratch_path" bash "$dir/ci-docker-label.sh" >/dev/null; then
  check ok 'label script runs a second time in one job'
else
  check fail 'label script failed on a second run in one job'
fi
rm -f "$scratch_path"
timeout 20 docker version --format '{{.Server.Version}}' >/dev/null 2>&1
rc=$?
check "$([ "$rc" -eq 0 ] && echo ok)" "docker answers within 20s after a second label run (got $rc)"

[ "$failures" -eq 0 ] || exit 1
printf 'label shim and sweep proven on this engine\n'
