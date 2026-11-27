#!/usr/bin/env bash
# Builds the release image (spec 016, acceptance criterion 3): the core image
# pinned by images/core-image.sha plus the ten production phars in
# /opt/riftal/plugins, under an immutable tag on the local daemon. Nothing is
# pushed anywhere. The script plugins of SHIPPED_PLUGINS go in the same place.
#
#   release-image.sh <directory holding the built phars>
#
#   GAME_COMMIT         required, the full riftal-game sha the phars and
#                       GRANTS_SQL were built from
#   GRANTS_SQL          required, the grants.sql of that commit
#   RELEASE_IMAGE       image name without its tag, default riftal/pocketmine-mp
#   RELEASE_DATE        UTC date in the tag, default today
#   LEVEL_LOCKS_DIR     where the <zone>.lock.json files are read, default
#                       designer/levels of the checkout, where each lock must
#                       be tracked at HEAD. A directory named here is read as
#                       it is, for the self-tests, and is not checked.
#   LEVEL_VOLUME_PREFIX prefix of the daemon's level build volumes, default
#                       riftal_smoke_level_
#
# The image also carries designer/world_index.json at /etc/riftal, every zone
# with a lock at /etc/riftal/levels/<zone>, and the boot scripts and digest
# list start-release.sh applies at /opt/riftal/boot (ADR 043). Each zone is
# copied out of its build volume through the pinned core image, and the build
# is refused, naming the zone, before docker build when the volume is missing,
# its manifest's content_sha256 differs from the lock's, its tree does not hash
# to its manifest's tree_sha256, or the lock's core_image is not the pinned
# image's id on this daemon. The labels org.riftal.world-index-sha256 and
# org.riftal.levels (<zone>=<content_sha256>:<tree_sha256>, comma separated)
# record them.
#
# The image records GAME_COMMIT and the sha256 of GRANTS_SQL in the labels
# org.riftal.game-commit and org.riftal.grants-sha256, which
# grants-revoke-check.sh reads to verify the file an operator supplies for the
# tag, and the riftal-infra commit in org.riftal.infra-commit. The file itself
# is not in the image.
#
# The tag is <date>-core<first 7 of the pinned pmmp-core sha>-game<first 7 of
# GAME_COMMIT>-infra<first 7 of the riftal-infra HEAD>, so it follows every
# input that changes the image. The commit, the Dockerfile and the core pin
# are all read from the checkout holding this script. The build is refused
# when that checkout is not the top of a git work tree of its own with a HEAD,
# when git cannot report its status, or when a tracked file in it differs from
# HEAD: the commit would not describe what was built. A tag that already
# exists is refused, never rebuilt, so a tag names one image on the daemon
# that built it, for as long as the tag exists there.
#
# Sourcing this file sets errexit, nounset and pipefail in the caller, sources
# images/core-image.sh and defines SCRIPT_DIR, release_tag, infra_commit,
# REQUIRED_PHARS, SHIPPED_PLUGINS, BOOT_SCRIPTS, plugin_config, bake_levels and
# main. It builds nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../images/core-image.sh"

REQUIRED_PHARS=(
  RiftalCustody.phar RiftalAccounts.phar contracts.phar
  RiftalMines.phar RiftalRanks.phar RiftalEconomy.phar
  RiftalGangs.phar RiftalRiots.phar RiftalPlots.phar RiftalAnvil.phar
)

# Script plugins read from images/plugins in this repository. The phars come
# from riftal-game; these are riftal-infra's own.
SHIPPED_PLUGINS=(RiftalDownstreamLimit.php)

# The scripts start-release.sh runs from /opt/riftal/boot, byte for byte the
# files the dev stack and CI run from images/plugins.
BOOT_SCRIPTS=(deliver-world-index.sh seed-levels.sh level-args.sh)

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
    printf '%s is not a git checkout with a commit; the riftal-infra commit cannot be named: %s\n' \
      "$dir" "$(git -C "$dir" rev-parse --verify HEAD 2>&1 >/dev/null)" >&2
    return 1
  fi
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
  real="$(cd "$dir" && pwd -P)"
  if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$real" ]; then
    printf '%s is not the top of its own git work tree; the riftal-infra commit cannot be named\n' "$dir" >&2
    return 1
  fi
  if ! status="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)"; then
    printf 'git status failed in %s, so it cannot be shown clean: %s\n' \
      "$dir" "$(git -C "$dir" status --porcelain --untracked-files=no 2>&1 >/dev/null)" >&2
    return 1
  fi
  if [ -n "$status" ]; then
    printf '%s has tracked changes since %s; commit them before building\n' "$dir" "$sha" >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

# $1 a plugin name. Prints the dev stack's config for it, which start-release.sh
# renders the database host and schema of.
plugin_config() {
  local images="$SCRIPT_DIR/../images/plugins"
  case "$1" in
    RiftalAccounts) printf '%s\n' "$images/RiftalAccounts.config.yml" ;;
    RiftalMines) printf '%s\n' "$images/instance-only/RiftalMines.config.yml.template" ;;
    *) printf '%s\n' "$images/instance-only/$1.config.yml" ;;
  esac
}

# $1 a level manifest, $2 the key. Prints the one hex digest the build wrote on
# its own line, nothing when the key is missing or repeated: the parse
# seed-levels.sh makes at boot.
manifest_digest() {
  local found
  found="$(sed -n "s/^ *\"$2\": *\"\\([0-9a-f]\\{64\\}\\)\",\\{0,1\\} *\$/\\1/p" "$1")"
  if [ "$(printf '%s' "$found" | grep -c .)" -eq 1 ]; then
    printf '%s' "$found"
  fi
}

# $1 a level folder. Prints the tree hash seed-levels.sh checks it against.
tree_sha256() {
  (
    cd "$1"
    find . -type f ! -path ./level-manifest.json -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum -- | sha256sum | cut -d' ' -f1
  )
}

# $1 zone, $2 the locks directory, $3 the volume prefix, $4 an empty directory
# to copy the level folder into. Prints "<content_sha256>:<tree_sha256>", or an
# ::error:: naming the zone, and returns 1. CORE_IMAGE is set.
bake_level() {
  local zone="$1" lock="$2/$1.lock.json" vol="$3$1" dest="$4"
  local named want_content want_core core_id content tree odd got

  if ! [[ "$zone" =~ ^[a-z0-9_]+$ ]]; then
    printf '::error::zone %s: %s is not a name matching [a-z0-9_]+\n' "$zone" "$lock"
    return 1
  fi
  named="$(jq -r '(.zone | strings) // ""' "$lock")" || named=""
  want_content="$(jq -r '(.content_sha256 | strings) // ""' "$lock")" || want_content=""
  want_core="$(jq -r '(.core_image | strings) // ""' "$lock")" || want_core=""
  if [ "$named" != "$zone" ] || ! [[ "$want_content" =~ ^[0-9a-f]{64}$ ]] || [ -z "$want_core" ]; then
    printf '::error::zone %s: %s is not one lock object naming this zone with a 64-digit content_sha256 and a core_image\n' "$zone" "$lock"
    return 1
  fi
  core_id="$(docker image inspect --format '{{.Id}}' "$CORE_IMAGE")" || return 1
  if [ "$want_core" != "$core_id" ]; then
    printf '::error::zone %s: its lock was built on core image %s, and the pinned %s is %s on this daemon; build and lock the zone against the pin\n' \
      "$zone" "$want_core" "$CORE_IMAGE" "$core_id"
    return 1
  fi
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    printf '::error::zone %s: build volume %s is not on this daemon; run designer level build %s\n' "$zone" "$vol" "$zone"
    return 1
  fi
  if ! docker run --rm -m 1g --cpus 1 --network none -v "$vol:/src:ro" --entrypoint tar "$CORE_IMAGE" -C /src -cf - . \
    | tar -xf - -C "$dest" --no-same-owner; then
    printf '::error::zone %s: copying build volume %s failed\n' "$zone" "$vol"
    return 1
  fi
  if ! chmod -R u+rwX "$dest"; then
    printf '::error::zone %s: the copy of %s cannot be made readable\n' "$zone" "$vol"
    return 1
  fi
  if ! odd="$(find "$dest" ! -type f ! -type d -print -quit)"; then
    printf '::error::zone %s: the copy of %s cannot be listed\n' "$zone" "$vol"
    return 1
  fi
  if [ -n "$odd" ]; then
    printf '::error::zone %s: %s in %s is neither a regular file nor a directory\n' "$zone" "${odd#"$dest"/}" "$vol"
    return 1
  fi
  content="$(manifest_digest "$dest/level-manifest.json" content_sha256 2>/dev/null)" || content=""
  tree="$(manifest_digest "$dest/level-manifest.json" tree_sha256 2>/dev/null)" || tree=""
  if [ -z "$content" ] || [ -z "$tree" ]; then
    printf '::error::zone %s: %s holds no level-manifest.json with one tree_sha256 and one content_sha256\n' "$zone" "$vol"
    return 1
  fi
  if [ "$content" != "$want_content" ]; then
    printf '::error::zone %s: the manifest in %s holds content_sha256 %s and the lock holds %s\n' "$zone" "$vol" "$content" "$want_content"
    return 1
  fi
  if ! got="$(tree_sha256 "$dest")"; then
    printf '::error::zone %s: the file tree of %s cannot be hashed\n' "$zone" "$vol"
    return 1
  fi
  if [ "$got" != "$tree" ]; then
    printf '::error::zone %s: the file tree of %s does not hash to the %s its manifest names\n' "$zone" "$vol" "$tree"
    return 1
  fi
  printf '%s:%s' "$content" "$tree"
}

# $1 the locks directory. Names each *.lock.json in it that the checkout's HEAD
# does not hold, one ::error:: per lock, and returns 1 for any. A lock is taken
# by glob, so an untracked one would otherwise ride under an infra-commit label
# that does not contain it.
tracked_locks() {
  local dir="$1" root="$SCRIPT_DIR/.." tracked lock rel bad=0
  if ! tracked="$(git -C "$root" -c core.quotePath=false ls-tree -r --name-only HEAD -- designer/levels)"; then
    printf '::error::git cannot list designer/levels at HEAD, so no lock can be shown tracked\n'
    return 1
  fi
  for lock in "$dir"/*.lock.json; do
    [ -e "$lock" ] || break
    rel="designer/levels/${lock##*/}"
    if ! grep -qxF -- "$rel" <<<"$tracked"; then
      printf '::error::%s is not tracked at the riftal-infra commit; commit it or remove it before building\n' "$rel"
      bad=1
    fi
  done
  return "$bad"
}

# $1 the build context. Lays out etc/ and boot/ in it: the world index, every
# zone with a lock, the boot scripts and the digest list of the index and of
# each zone's manifest. Sets INDEX_SHA and LEVELS_LABEL to what the labels hold.
# The locks are those of designer/levels, each tracked at HEAD, unless
# LEVEL_LOCKS_DIR names another directory, which is not checked against git.
# The caller tests this function's status, which turns errexit off inside it,
# so every command checks its own.
bake_levels() {
  local ctx="$1" locks="${LEVEL_LOCKS_DIR:-$SCRIPT_DIR/../designer/levels}"
  local prefix="${LEVEL_VOLUME_PREFIX:-riftal_smoke_level_}" index="$SCRIPT_DIR/../designer/world_index.json"
  local lock zone pair list name digest
  INDEX_SHA="" LEVELS_LABEL=""

  if ! command -v jq >/dev/null 2>&1; then
    printf '::error::jq is not installed, so no zone lock can be read\n'
    return 1
  fi
  if [ ! -s "$index" ]; then
    printf '::error::%s is missing or empty; the image carries it at /etc/riftal/world_index.json\n' "$index"
    return 1
  fi
  if [ ! -d "$locks" ]; then
    printf '::error::%s is not a directory, so no zone lock can be read\n' "$locks"
    return 1
  fi

  if [ -z "${LEVEL_LOCKS_DIR:-}" ]; then
    tracked_locks "$locks" || return 1
  fi

  mkdir -p "$ctx/etc/levels" "$ctx/boot" || return 1
  cp "$index" "$ctx/etc/world_index.json" || return 1
  INDEX_SHA="$(sha256sum "$ctx/etc/world_index.json" | cut -d' ' -f1)" || return 1
  list="$INDEX_SHA  /etc/riftal/world_index.json"$'\n'
  for lock in "$locks"/*.lock.json; do
    [ -e "$lock" ] || break
    zone="${lock##*/}"
    zone="${zone%.lock.json}"
    mkdir "$ctx/etc/levels/$zone" || return 1
    pair="$(bake_level "$zone" "$locks" "$prefix" "$ctx/etc/levels/$zone")" || {
      printf '%s\n' "$pair"
      return 1
    }
    LEVELS_LABEL+="${LEVELS_LABEL:+,}$zone=$pair"
    digest="$(sha256sum "$ctx/etc/levels/$zone/level-manifest.json" | cut -d' ' -f1)" || return 1
    list+="$digest  /etc/riftal/levels/$zone/level-manifest.json"$'\n'
  done
  if [ -z "$LEVELS_LABEL" ]; then
    printf '::error::%s holds no <zone>.lock.json, and the image would carry no level\n' "$locks"
    return 1
  fi

  for name in "${BOOT_SCRIPTS[@]}"; do
    cp "$SCRIPT_DIR/../images/plugins/$name" "$ctx/boot/$name" || return 1
    chmod 0555 "$ctx/boot/$name" || return 1
  done
  printf '%s' "$list" >"$ctx/boot/etc-riftal.sha256" || return 1
  chmod 0444 "$ctx/boot/etc-riftal.sha256" || return 1
  find "$ctx/etc" -type d -exec chmod 0755 {} + || return 1
  find "$ctx/etc" -type f -exec chmod 0444 {} + || return 1
}

main() {
  local phars="${1:?usage: release-image.sh <directory holding the built phars>}"
  local image="${RELEASE_IMAGE:-riftal/pocketmine-mp}"
  local date="${RELEASE_DATE:-$(date -u +%F)}"
  local name tag ref ctx sums="" scripts="" id
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

  infra="$(infra_commit "$SCRIPT_DIR/.." 2>&1)" || {
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
  trap 'chmod -R u+rwX "$ctx" 2>/dev/null; rm -rf "$ctx"' RETURN
  mkdir "$ctx/plugins"
  cp "$SCRIPT_DIR/../images/release/Dockerfile" "$ctx/Dockerfile"
  for name in "${REQUIRED_PHARS[@]}"; do
    cp "$phars/$name" "$ctx/plugins/$name"
    chmod 0444 "$ctx/plugins/$name"
    sums+="${sums:+,}$name=$(sha256sum "$ctx/plugins/$name" | cut -d' ' -f1)"
  done

  for name in "${SHIPPED_PLUGINS[@]}"; do
    cp "$SCRIPT_DIR/../images/plugins/$name" "$ctx/plugins/$name"
    chmod 0444 "$ctx/plugins/$name"
    scripts+="${scripts:+,}$name=$(sha256sum "$ctx/plugins/$name" | cut -d' ' -f1)"
  done

  cp "$SCRIPT_DIR/../images/release/start-release.sh" "$ctx/start-release.sh"
  chmod 0555 "$ctx/start-release.sh"
  for name in RiftalAccounts RiftalMines RiftalRanks RiftalEconomy; do
    mkdir -p "$ctx/plugin_data/$name"
    cp "$(plugin_config "$name")" "$ctx/plugin_data/$name/config.yml"
    chmod 0444 "$ctx/plugin_data/$name/config.yml"
  done

  bake_levels "$ctx" || return 1

  docker build \
    --build-arg "CORE_REPO=${CORE_IMAGE%:*}" \
    --build-arg "CORE_TAG=${CORE_IMAGE##*:}" \
    --label "org.riftal.core-image=$CORE_IMAGE" \
    --label "org.riftal.phars=$sums" \
    --label "org.riftal.script-plugins=$scripts" \
    --label "org.riftal.game-commit=$commit" \
    --label "org.riftal.infra-commit=$infra" \
    --label "org.riftal.grants-sha256=$grants_sha" \
    --label "org.riftal.world-index-sha256=$INDEX_SHA" \
    --label "org.riftal.levels=$LEVELS_LABEL" \
    -t "$ref" "$ctx" || return 1

  id="$(docker image inspect --format '{{.Id}}' "$ref")" || return 1
  printf 'release image %s (%s) built from %s\n' "$ref" "$id" "$CORE_IMAGE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
