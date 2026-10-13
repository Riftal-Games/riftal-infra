#!/usr/bin/env bash
# Pulls the newest mysql:8 for this job, so the self-tests that run it exercise
# the current release of that floating tag and not whatever copy the
# self-hosted runner cached on an earlier run (riftal-infra#472).
# images/compose.yaml sets no pull_policy, so compose pulls mysql:8 only when
# the image is missing: a dev stack can run an older copy than CI does.
#
# The self-tests name mysql:8 themselves, so this also fails when a service in
# the compose file runs any other mysql or mariadb image: a pull of mysql:8
# would then prove nothing about the stack. Every image: value must be a plain
# reference on its own line. A variable, an anchor or a flow mapping cannot be
# classified, so it fails rather than passing unread. CI only. A local
# self-test run never pulls.
set -euo pipefail

image=mysql:8
compose="${1:-images/compose.yaml}"

if [ ! -f "$compose" ]; then
  printf '::error::%s not found, cannot confirm the stack runs %s\n' "$compose" "$image" >&2
  exit 1
fi

plain="^[[:space:]]*image:[[:space:]]*[\"']?([[:alnum:]._/:@-]+)[\"']?[[:space:]]*(#.*)?\$"
key="(^|[[:space:]{,])[\"']?image[\"']?[[:space:]]*:"
found=0
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  line="${line%$'\r'}"
  if [[ "$line" =~ ^[[:space:]]*# ]] || ! [[ "$line" =~ $key ]]; then
    continue
  fi
  if ! [[ "$line" =~ $plain ]]; then
    printf '::error::%s:%d cannot classify this image line, so cannot confirm the stack runs %s: %s\n' \
      "$compose" "$n" "$image" "$line" >&2
    exit 1
  fi
  name="${BASH_REMATCH[1]}"
  case "${name,,}" in
    *mysql* | *mariadb*) ;;
    *) continue ;;
  esac
  if [ "$name" != "$image" ]; then
    printf '::error::%s runs %s but the self-tests run %s\n' "$compose" "$name" "$image" >&2
    exit 1
  fi
  found=$((found + 1))
done <"$compose"

if [ "$found" -eq 0 ]; then
  printf '::error::%s names no mysql image, cannot confirm the stack runs %s\n' "$compose" "$image" >&2
  exit 1
fi

if ! docker pull "$image"; then
  printf '::error::docker pull %s failed. The mysql self-tests would run a cached image the stack may no longer pull, so this job stops here.\n' "$image" >&2
  exit 1
fi

# The run log records the exact image every later self-test ran.
docker image inspect --format '{{join .RepoDigests " "}}' "$image"
