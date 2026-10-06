#!/usr/bin/env bash
# Removes every container and network this job run created, found by the label
# ci-docker-label.sh stamps on them. Runs last, whether the job passed, failed
# or was cancelled. Fails if anything carrying the label is still there after
# the sweep, so a leak shows up as a red step rather than as a full runner.
set -uo pipefail

label="riftal.ci.job=${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}-${GITHUB_JOB:-job}"
filter="label=$label"

# An unreachable daemon lists nothing, and an empty list would read as a clean
# sweep. Every caller runs this in a command substitution followed by
# `|| exit 1`, because the exit here leaves only that subshell.
query() {
  if ! out="$(docker "$@" --filter "$filter")"; then
    printf 'docker %s failed, so nothing is known to be removed\n' "$1" >&2
    exit 1
  fi
  printf '%s' "$out"
}

left="$(query ps -a --format '{{.Names}} ({{.Status}})')" || exit 1
if [ -n "$left" ]; then
  printf 'containers left by this job:\n%s\n' "$left"
  ids_out="$(query ps -aq)" || exit 1
  mapfile -t ids <<<"$ids_out"
  # SIGTERM first. A PocketMine server and mysqld both shut down cleanly on it,
  # and a server whose stdin went with the cancelled step never stops by
  # itself. 60 seconds covers a mysql:8 flush on the shared runner engine.
  docker stop -t 60 "${ids[@]}" >/dev/null
  # Containers started with --rm are already gone, or going, once stopped.
  for id in "${ids[@]}"; do
    docker rm -v "$id" >/dev/null 2>&1 || true
  done
fi

# --rm removal finishes asynchronously after the stop returns, and a network
# refuses removal while any container is still attached, so every pass retries
# the networks rather than only waiting on them.
for _ in $(seq 1 30); do
  networks="$(query network ls -q)" || exit 1
  if [ -n "$networks" ]; then
    mapfile -t nets <<<"$networks"
    for net in "${nets[@]}"; do
      docker network rm "$net" >/dev/null 2>&1 || true
    done
  fi
  containers="$(query ps -aq)" || exit 1
  networks="$(query network ls -q)" || exit 1
  remaining="$containers$networks"
  [ -z "$remaining" ] && break
  sleep 1
done

if [ -n "$remaining" ]; then
  printf 'still present after the sweep:\n'
  docker ps -a --filter "$filter" --format '{{.Names}} ({{.Status}})'
  docker network ls --filter "$filter" --format '{{.Name}}'
  exit 1
fi
printf 'no container or network carries %s\n' "$label"
