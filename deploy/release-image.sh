#!/usr/bin/env bash
# Builds the release image (spec 016, acceptance criterion 3): the core image
# pinned by images/core-image.sha plus the plugin phars, under an immutable tag
# on the local daemon. Nothing is pushed anywhere.
#
#   release-image.sh <directory holding the built phars>
#
#   RELEASE_IMAGE  image name without its tag, default riftal/pocketmine-mp
#   RELEASE_DATE   UTC date in the tag, default today
#
# The tag is core-<date>-<first 7 of the pinned pmmp-core sha>. A tag that
# already exists is refused, never rebuilt, so a tag names one image for as long
# as it exists. Two builds of the same core sha on one date therefore need the
# date or the pin to differ.
#
# Sourcing this file defines release_tag and runs nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../images/core-image.sh"

REQUIRED_PHARS=(RiftalCustody.phar RiftalAccounts.phar contracts.phar)

# $1 repo, $2 UTC date as YYYY-MM-DD, $3 the full 40-character sha. Prints the
# tag, or a message on stderr and returns 1.
release_tag() {
  local repo="$1" date="$2" sha="$3" tag
  if ! [[ "$repo" =~ ^[a-z][a-z0-9-]*$ ]]; then
    printf 'repo "%s" is not lowercase letters, digits and hyphens\n' "$repo" >&2
    return 1
  fi
  if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf 'date "%s" is not YYYY-MM-DD\n' "$date" >&2
    return 1
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'sha "%s" is not a full 40-character sha\n' "$sha" >&2
    return 1
  fi
  tag="$repo-$date-${sha:0:7}"
  printf '%s\n' "$tag"
}

main() {
  local phars="${1:?usage: release-image.sh <directory holding the built phars>}"
  local image="${RELEASE_IMAGE:-riftal/pocketmine-mp}"
  local date="${RELEASE_DATE:-$(date -u +%F)}"
  local name tag ref ctx sums="" id

  for name in "${REQUIRED_PHARS[@]}"; do
    if [ ! -s "$phars/$name" ]; then
      printf '::error::%s is missing or empty in %s; every instance loads it\n' "$name" "$phars"
      return 1
    fi
  done

  core_image || return 1
  tag="$(release_tag core "$date" "${CORE_IMAGE#*:}")" || return 1
  ref="$image:$tag"

  if docker image inspect "$ref" >/dev/null 2>&1; then
    printf '::error::%s already exists; a release tag is immutable and is never rebuilt\n' "$ref"
    return 1
  fi

  ctx="$(mktemp -d)"
  trap 'rm -rf "$ctx"' RETURN
  mkdir "$ctx/plugins"
  cp "$SCRIPT_DIR/../images/release/Dockerfile" "$ctx/Dockerfile"
  for name in "${REQUIRED_PHARS[@]}"; do
    cp "$phars/$name" "$ctx/plugins/$name"
    sums+="${sums:+,}$name=$(sha256sum "$ctx/plugins/$name" | cut -d' ' -f1)"
  done

  docker build \
    --build-arg "CORE_REPO=${CORE_IMAGE%:*}" \
    --build-arg "CORE_TAG=${CORE_IMAGE##*:}" \
    --label "org.riftal.core-image=$CORE_IMAGE" \
    --label "org.riftal.phars=$sums" \
    -t "$ref" "$ctx"

  id="$(docker image inspect --format '{{.Id}}' "$ref")"
  printf 'release image %s (%s) built from %s\n' "$ref" "$id" "$CORE_IMAGE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
