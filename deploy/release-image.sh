#!/usr/bin/env bash
# Builds the release image (spec 016, acceptance criterion 3): the core image
# pinned by images/core-image.sha plus the ten production phars in
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
#   INFRA_DIR      a test seam, never set for a release: the commit is read
#                  from this checkout, default the one holding this script,
#                  while the Dockerfile and the core pin are always read from
#                  the one holding this script
#
# The image records GAME_COMMIT and the sha256 of GRANTS_SQL in the labels
# org.riftal.game-commit and org.riftal.grants-sha256, which
# grants-revoke-check.sh reads to verify the file an operator supplies for the
# tag, and the riftal-infra commit in org.riftal.infra-commit. The file itself
# is not in the image.
#
# The tag is <date>-core<first 7 of the pinned pmmp-core sha>-game<first 7 of
# GAME_COMMIT>-infra<first 7 of the riftal-infra HEAD>, so it follows every
# input that changes the image. The build is refused when INFRA_DIR is not the
# top of a git work tree of its own with a HEAD, when git cannot report its
# status, or when a tracked file in it differs from HEAD: the commit would not
# describe what was built. A tag that already exists is
# refused, never rebuilt, so a tag names one image on the daemon that built it,
# for as long as the tag exists there.
#
# Sourcing this file sets errexit, nounset and pipefail in the caller, sources
# images/core-image.sh and defines SCRIPT_DIR, release_tag, infra_commit,
# REQUIRED_PHARS and main. It builds nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../images/core-image.sh"

REQUIRED_PHARS=(
  RiftalCustody.phar RiftalAccounts.phar contracts.phar
  RiftalMines.phar RiftalRanks.phar RiftalEconomy.phar
  RiftalGangs.phar RiftalRiots.phar RiftalPlots.phar RiftalAnvil.phar
)

# $1 UTC date as YYYY-MM-DD, $2 the pinned pmmp-core sha, $3 the riftal-game
# commit, $4 the riftal-infra commit, each a full 40-character sha. Prints the
# tag, or a message on stderr and returns 1.
release_tag() {
  local date="$1" label sha
  if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf 'date "%s" is not YYYY-MM-DD\n' "$date" >&2
    return 1
  fi
  for label in core:"$2" game:"$3" infra:"$4"; do
    sha="${label#*:}"
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      printf '%s sha "%s" is not a full 40-character sha\n' "${label%%:*}" "$sha" >&2
      return 1
    fi
  done
  printf '%s-core%s-game%s-infra%s\n' "$date" "${2:0:7}" "${3:0:7}" "${4:0:7}"
}

# $1 the riftal-infra checkout. Prints its HEAD sha, or a message on stderr and
# returns 1 when it is not the top of its own git work tree with a commit, when
# git cannot report its status, or when a tracked file differs from that commit.
# Git looks in parent directories, so a directory inside another repository
# would otherwise name that repository's commit. Untracked files are not inputs
# to the build.
infra_commit() {
  local dir="$1" sha top real status
  if ! sha="$(git -C "$dir" rev-parse --verify HEAD 2>/dev/null)"; then
    printf '%s is not a git checkout with a commit; the riftal-infra commit cannot be named\n' "$dir" >&2
    return 1
  fi
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
  real="$(cd "$dir" && pwd -P)"
  if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$real" ]; then
    printf '%s is not the top of its own git work tree; the riftal-infra commit cannot be named\n' "$dir" >&2
    return 1
  fi
  if ! status="$(git -C "$dir" status --porcelain --untracked-files=no 2>&1)"; then
    printf 'git status failed in %s, so it cannot be shown clean: %s\n' "$dir" "$status" >&2
    return 1
  fi
  if [ -n "$status" ]; then
    printf '%s has tracked changes since %s; commit them before building\n' "$dir" "$sha" >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

main() {
  local phars="${1:?usage: release-image.sh <directory holding the built phars>}"
  local image="${RELEASE_IMAGE:-riftal/pocketmine-mp}"
  local date="${RELEASE_DATE:-$(date -u +%F)}"
  local name tag ref ctx sums="" id
  local commit="${GAME_COMMIT:-}" grants="${GRANTS_SQL:-}" grants_sha infra

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

  infra="$(infra_commit "${INFRA_DIR:-$SCRIPT_DIR/..}" 2>&1)" || {
    printf '::error::%s\n' "$infra"
    return 1
  }

  core_image || return 1
  tag="$(release_tag "$date" "${CORE_IMAGE#*:}" "$commit" "$infra")" || return 1
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
    --label "org.riftal.infra-commit=$infra" \
    --label "org.riftal.grants-sha256=$grants_sha" \
    -t "$ref" "$ctx" || return 1

  id="$(docker image inspect --format '{{.Id}}' "$ref")" || return 1
  printf 'release image %s (%s) built from %s\n' "$ref" "$id" "$CORE_IMAGE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
