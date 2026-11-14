#!/usr/bin/env bash
# Removes every container, network, named volume and image this job run created,
# found by the label ci-docker-label.sh stamps on them. Runs last, whether the job
# passed, failed or was cancelled. Fails if anything carrying the label is still
# there after the sweep, so a leak shows up as a red step rather than as a full
# runner.
set -uo pipefail

label="riftal.ci.job=${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}-${GITHUB_JOB:-job}"
filter="label=$label"

# A step cancelled at the job timeout can leave its docker client alive, still
# queued behind other builds on a busy daemon. The daemon then creates the
# container after the listing below, and the runner kills the client only once
# this step is over, so the container stays in Created. Stopping the clients
# first lets the settle wait cover that create. Nothing here has started a
# docker client of its own yet, so every match is an earlier step's.
stop_stray_clients() {
  local proc pid env comm stopped=0
  for proc in /proc/[0-9]*; do
    pid="${proc#/proc/}"
    { read -r comm <"$proc/comm"; } 2>/dev/null || continue
    [ "$comm" = docker ] || continue
    env="$(tr '\0' '\n' <"$proc/environ" 2>/dev/null)" || continue
    grep -qxF "GITHUB_RUN_ID=$GITHUB_RUN_ID" <<<"$env" || continue
    grep -qxF "GITHUB_RUN_ATTEMPT=$GITHUB_RUN_ATTEMPT" <<<"$env" || continue
    grep -qxF "GITHUB_JOB=${GITHUB_JOB:-job}" <<<"$env" || continue
    if kill -TERM "$pid" 2>/dev/null; then
      printf 'stopped a docker client left running by an earlier step: pid %s\n' "$pid"
      stopped=1
    fi
  done
  [ "$stopped" -eq 0 ] || sleep 5
}
stop_stray_clients

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

volumes_left="$(query volume ls --format '{{.Name}}')" || exit 1
if [ -n "$volumes_left" ]; then
  printf 'volumes left by this job:\n%s\n' "$volumes_left"
fi

# --rm removal finishes asynchronously after the stop returns, and a network or
# a volume refuses removal while any container still uses it, so every pass
# retries removing all three. A daemon can still create a container for a
# stopped client after the listing above, so every pass removes those too.
for _ in $(seq 1 30); do
  late_out="$(query ps -aq)" || exit 1
  if [ -n "$late_out" ]; then
    mapfile -t late_ids <<<"$late_out"
    docker rm -f -v "${late_ids[@]}" >/dev/null 2>&1 || true
  fi
  networks="$(query network ls -q)" || exit 1
  if [ -n "$networks" ]; then
    mapfile -t nets <<<"$networks"
    for net in "${nets[@]}"; do
      docker network rm "$net" >/dev/null 2>&1 || true
    done
  fi
  volumes="$(query volume ls -q)" || exit 1
  if [ -n "$volumes" ]; then
    mapfile -t vols <<<"$volumes"
    for vol in "${vols[@]}"; do
      docker volume rm "$vol" >/dev/null 2>&1 || true
    done
  fi
  query images --format '{{.Repository}}:{{.Tag}}' | xargs -r docker rmi >/dev/null 2>&1
  containers="$(query ps -aq)" || exit 1
  networks="$(query network ls -q)" || exit 1
  volumes="$(query volume ls -q)" || exit 1
  images="$(query images -q)" || exit 1
  remaining="$containers$networks$volumes$images"
  [ -z "$remaining" ] && break
  sleep 1
done

if [ -n "$remaining" ]; then
  printf 'still present after the sweep:\n'
  docker ps -a --filter "$filter" --format '{{.Names}} ({{.Status}})'
  docker network ls --filter "$filter" --format '{{.Name}}'
  docker volume ls --filter "$filter" --format '{{.Name}}'
  docker images --filter "$filter" --format '{{.Repository}}:{{.Tag}}'
  exit 1
fi
printf 'no container, network, volume or image carries %s\n' "$label"
