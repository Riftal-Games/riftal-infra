#!/usr/bin/env bash
# Pulls mysql:8 for this job, so the self-tests that run it exercise the image
# the dev stack pulls and not whatever copy the self-hosted runner cached on an
# earlier run (riftal-infra#472). mysql:8 is a floating tag: without a pull, a
# new release reaches the stack and never reaches CI.
#
# The self-tests name mysql:8 themselves, so this also fails when a service in
# the compose file runs a different mysql image: a pull of mysql:8 would then
# prove nothing about the stack. CI only. A local self-test run never pulls.
set -euo pipefail

image=mysql:8
compose="${1:-images/compose.yaml}"

if [ ! -f "$compose" ]; then
  printf '::error::%s not found, cannot confirm the stack runs %s\n' "$compose" "$image" >&2
  exit 1
fi

mapfile -t found < <(sed -nE \
  "s/^[[:space:]]*image:[[:space:]]*[\"']?(mysql[^\"'[:space:]]*)[\"']?[[:space:]]*(#.*)?\$/\1/p" \
  "$compose")
if [ "${#found[@]}" -eq 0 ]; then
  printf '::error::%s names no mysql image, cannot confirm the stack runs %s\n' "$compose" "$image" >&2
  exit 1
fi
for name in "${found[@]}"; do
  if [ "$name" != "$image" ]; then
    printf '::error::%s runs %s but the self-tests run %s\n' "$compose" "$name" "$image" >&2
    exit 1
  fi
done

if ! docker pull "$image"; then
  printf '::error::docker pull %s failed. The mysql self-tests would run a cached image the stack may no longer pull, so this job stops here.\n' "$image" >&2
  exit 1
fi

# The run log records the exact image every later self-test ran.
docker image inspect --format '{{join .RepoDigests " "}}' "$image"
