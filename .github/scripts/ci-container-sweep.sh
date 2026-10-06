#!/usr/bin/env bash
# Removes every container and network this job run created, found by the label
# ci-docker-label.sh stamps on them. Runs last, whether the job passed, failed
# or was cancelled. Fails if anything carrying the label is still there after
# the sweep, so a leak shows up as a red step rather than as a full runner.
set -uo pipefail

label="riftal.ci.job=${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}-${GITHUB_JOB:-job}"
filter="label=$label"

left="$(docker ps -a --filter "$filter" --format '{{.Names}} ({{.Status}})')"
if [ -n "$left" ]; then
  printf 'containers left by this job:\n%s\n' "$left"
  mapfile -t ids < <(docker ps -aq --filter "$filter")
  # SIGTERM first. A PocketMine server and mysqld both shut down cleanly on it,
  # and a server whose stdin went with the cancelled step never stops by
  # itself. 60 seconds covers a mysql:8 flush on the shared runner engine.
  docker stop -t 60 "${ids[@]}" >/dev/null
  # Containers started with --rm are already gone, or going, once stopped.
  for id in "${ids[@]}"; do
    docker rm -v "$id" >/dev/null 2>&1 || true
  done
fi

mapfile -t nets < <(docker network ls -q --filter "$filter")
for net in "${nets[@]}"; do
  docker network rm "$net" >/dev/null 2>&1 || true
done

# --rm removal finishes asynchronously after the stop returns.
for _ in $(seq 1 30); do
  remaining="$(docker ps -aq --filter "$filter")$(docker network ls -q --filter "$filter")"
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
