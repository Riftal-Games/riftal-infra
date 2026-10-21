#!/usr/bin/env bash
# Builds the release image (spec 016, acceptance criterion 3): the core image
# pinned by images/core-image.sha plus the six production phars in
# /opt/riftal/plugins, under an immutable tag on the local daemon. Nothing is
# pushed anywhere.
#
#   release-image.sh <directory holding the built phars>
#
#   GAME_COMMIT    required, the full riftal-game sha the phars and GRANTS_SQL
#                  were built from
#   GRANTS_SQL     required, the grants.sql of that commit
#   RELEASE_IMAGE  image name without its tag, default riftal/pocketmine-mp
#   RELEASE_DATE   UTC date in the tag, default today
#
# The image records GAME_COMMIT and the sha256 of GRANTS_SQL in the labels
# org.riftal.game-commit and org.riftal.grants-sha256, which
# grants-revoke-check.sh reads to verify the file an operator supplies for the
# tag. The file itself is not in the image.
#
# The tag is core-<date>-<first 7 of the pinned pmmp-core sha>. A tag that
# already exists is refused, never rebuilt, so a tag names one image on the
# daemon that built it, for as long as the tag exists there. Two builds of the
# same core sha on one date therefore need the date or the pin to differ.
#
# Sourcing this file sets errexit, nounset and pipefail in the caller, sources
# images/core-image.sh and defines release_tag, REQUIRED_PHARS and main. It
# builds nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../images/core-image.sh"

REQUIRED_PHARS=(
  RiftalCustody.phar RiftalAccounts.phar contracts.phar
  RiftalMines.phar RiftalRanks.phar RiftalEconomy.phar
)

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
  local commit="${GAME_COMMIT:-}" grants="${GRANTS_SQL:-}" grants_sha

  for name in "${REQUIRED_PHARS[@]}"; do
    if [ ! -s "$phars/$name" ]; then
      printf '::error::%s is missing or empty in %s; the release image carries it\n' "$name" "$phars"
      return 1
    fi
  done

  if ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    printf '::error::GAME_COMMIT "%s" is not a full 40-character riftal-game sha\n' "$commit"
    return 1
  fi
  if [ ! -f "$grants" ] || [ ! -s "$grants" ]; then
    printf '::error::GRANTS_SQL "%s" is not a non-empty regular file; the image records its sha256\n' "$grants"
    return 1
  fi
  grants_sha="$(sha256sum "$grants" | cut -d' ' -f1)"

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
    chmod 0444 "$ctx/plugins/$name"
    sums+="${sums:+,}$name=$(sha256sum "$ctx/plugins/$name" | cut -d' ' -f1)"
  done

  docker build \
    --build-arg "CORE_REPO=${CORE_IMAGE%:*}" \
    --build-arg "CORE_TAG=${CORE_IMAGE##*:}" \
    --label "org.riftal.core-image=$CORE_IMAGE" \
    --label "org.riftal.phars=$sums" \
    --label "org.riftal.game-commit=$commit" \
    --label "org.riftal.grants-sha256=$grants_sha" \
    -t "$ref" "$ctx" || return 1

  id="$(docker image inspect --format '{{.Id}}' "$ref")" || return 1
  printf 'release image %s (%s) built from %s\n' "$ref" "$id" "$CORE_IMAGE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
