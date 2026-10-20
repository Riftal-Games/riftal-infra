#!/usr/bin/env bash
# Sourced, never run. The bot library comes from one pinned image and nowhere
# else (ADR 024 item 4, the riftal-infra#363 pattern).
#
# riftal-pm's CI tags riftal-devtools:<full riftal-pm sha> on the self-hosted
# runners' shared Docker daemon on each push to main. devtools-image.sha beside
# this file names the one the bot-proofs job runs. A missing tag fails; nothing
# here pulls, falls back or skips.

# $1 the sha file, devtools-image.sha beside this script when omitted. Sets
# DEVTOOLS_IMAGE to the pinned tag, or prints an ::error:: and returns 1.
devtools_image() {
  local file="${1:-$(dirname "${BASH_SOURCE[0]}")/devtools-image.sha}" sha tag
  DEVTOOLS_IMAGE=
  if ! sha="$(tr -d '[:space:]' < "$file")"; then
    printf '::error::cannot read the pinned devtools image sha from %s\n' "$file"
    return 1
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf '::error::%s holds "%s", not a full 40-character riftal-pm sha\n' "$file" "$sha"
    return 1
  fi
  tag="riftal-devtools:$sha"
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    printf '::error::pinned devtools image %s is not on this Docker daemon; a push run of riftal-pm main at that sha tags it\n' "$tag"
    return 1
  fi
  DEVTOOLS_IMAGE="$tag"
}

# $1 the directory to copy /devtools into, which must not exist yet. Prints
# the pinned tag and its image id. The container is only ever created, never
# started, and is gone before this returns.
devtools_extract() {
  local dest="$1" name id
  name="riftal_smoke_ci_${GITHUB_RUN_ID:?}_${GITHUB_RUN_ATTEMPT:?}_devtools"
  # docker cp into an existing directory nests /devtools inside it.
  if [ -e "$dest" ]; then
    printf '::error::%s already exists\n' "$dest"
    return 1
  fi
  devtools_image "${2:-}" || return 1
  if ! docker create --rm -m 1g --cpus 1 --name "$name" "$DEVTOOLS_IMAGE" >/dev/null; then
    printf '::error::cannot create a container from %s\n' "$DEVTOOLS_IMAGE"
    return 1
  fi
  if ! docker cp "$name:/devtools" "$dest" >/dev/null; then
    docker rm -v "$name" >/dev/null 2>&1 || true
    printf '::error::cannot copy /devtools out of %s\n' "$DEVTOOLS_IMAGE"
    return 1
  fi
  if ! docker rm -v "$name" >/dev/null; then
    printf '::error::cannot remove container %s\n' "$name"
    return 1
  fi
  id="$(docker image inspect --format '{{.Id}}' "$DEVTOOLS_IMAGE")" || return 1
  printf 'devtools image %s (%s) extracted to %s\n' "$DEVTOOLS_IMAGE" "$id" "$dest"
}
