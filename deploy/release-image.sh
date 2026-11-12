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
#   MIGRATIONS_DIR      required, riftal-game's lib/resources/sql/migrations/ at
#                       that commit, holding at least one .sql file
#   RELEASE_IMAGE       image name without its tag, default riftal/pocketmine-mp
#   BACKUP_IMAGE        the ops image's name without its tag, default riftal/backup
#   RELEASE_DATE        UTC date in the tag, default today
#   LEVEL_LOCKS_DIR     where the <zone>.lock.json files are read, default
#                       designer/levels of the checkout
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
# is in the ops image, not this one.
#
# The same run builds the ops image first, under the same tag string, from the
# same checkout (ADR 045 item 1): the image images/backup/Dockerfile builds plus
# the layer images/release/Dockerfile.backup adds. The layer holds /opt/riftal/ops,
# the HOST_SCRIPTS with the runbooks and the zone locks, /opt/riftal/sql, holding
# MIGRATIONS_DIR and GRANTS_SQL, and /opt/riftal/ops.sha256, a sha256sum list of
# every file in both. Its labels org.riftal.infra-commit, game-commit and
# grants-sha256 equal this image's, and it adds org.riftal.migrations-sha256 and
# org.riftal.ops-sha256. This image's org.riftal.backup-image is the ops image's
# id, since the base floats and the tag alone does not fix the bytes. The build
# is refused, naming the script, when a top-level .sh of deploy/, migrations/ or
# images/ is on neither or both of HOST_SCRIPTS and NOT_CARRIED_SCRIPTS.
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
# REQUIRED_PHARS, SHIPPED_PLUGINS, BOOT_SCRIPTS, HOST_SCRIPTS,
# NOT_CARRIED_SCRIPTS, plugin_config, classify_scripts, bake_levels, bake_ops and
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

# The scripts an operator runs on a host, which the ops image carries.
HOST_SCRIPTS=(
  deploy/backup.sh deploy/backup-loop.sh deploy/restore.sh deploy/wipe.sh
  deploy/wipe-volumes.sh deploy/wipe-check.sh deploy/binlog-check.sh
  deploy/custody-alert-check.sh deploy/grants-revoke-check.sh
  deploy/write-latency-probe.sh deploy/write-latency-check.sh
  migrations/run-migrations.sh images/loads-check.sh
)

# The scripts no host runs: CI only (ADR 027), or run on the building daemon.
# instance-levels-check.sh reads every definition and lock; a boot applies its
# per-definition rule from level-args.sh in the release image.
NOT_CARRIED_SCRIPTS=(
  deploy/bot-proofs.sh deploy/capture-proofs.sh deploy/instance-levels-check.sh
  deploy/release-image.sh deploy/release-fixture.sh
  deploy/binlog-selftest.sh deploy/custody-alert-check-selftest.sh
  deploy/grants-revoke-check-selftest.sh deploy/instance-levels-check-selftest.sh
  deploy/level-replace-selftest.sh deploy/release-image-selftest.sh
  deploy/release-start-selftest.sh deploy/restore-selftest.sh deploy/selftest.sh
  deploy/wipe-selftest.sh deploy/wipe-volumes-selftest.sh
  deploy/write-latency-probe-selftest.sh deploy/write-latency-selftest.sh
  migrations/selftest.sh images/core-image.sh images/core-image-selftest.sh
  images/custody-selftest.sh images/devtools-image.sh images/dump-login-selftest.sh
  images/refresh-riftal-game-snapshot.sh
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
  local named want_content want_core core_id content tree odd

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
  chmod -R u+rwX "$dest"
  odd="$(find "$dest" ! -type f ! -type d -print -quit)"
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
  if [ "$(tree_sha256 "$dest")" != "$tree" ]; then
    printf '::error::zone %s: the file tree of %s does not hash to the %s its manifest names\n' "$zone" "$vol" "$tree"
    return 1
  fi
  printf '%s:%s' "$content" "$tree"
}

# $1 the build context. Lays out etc/ and boot/ in it: the world index, every
# zone with a lock, the boot scripts and the digest list of the index and of
# each zone's manifest. Sets INDEX_SHA and LEVELS_LABEL to what the labels hold.
bake_levels() {
  local ctx="$1" locks="${LEVEL_LOCKS_DIR:-$SCRIPT_DIR/../designer/levels}"
  local prefix="${LEVEL_VOLUME_PREFIX:-riftal_smoke_level_}" index="$SCRIPT_DIR/../designer/world_index.json"
  local lock zone pair list name
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

  mkdir -p "$ctx/etc/levels" "$ctx/boot"
  cp "$index" "$ctx/etc/world_index.json"
  INDEX_SHA="$(sha256sum "$ctx/etc/world_index.json" | cut -d' ' -f1)"
  list="$INDEX_SHA  /etc/riftal/world_index.json"$'\n'
  for lock in "$locks"/*.lock.json; do
    [ -e "$lock" ] || break
    zone="${lock##*/}"
    zone="${zone%.lock.json}"
    mkdir "$ctx/etc/levels/$zone"
    pair="$(bake_level "$zone" "$locks" "$prefix" "$ctx/etc/levels/$zone")" || {
      printf '%s\n' "$pair"
      return 1
    }
    LEVELS_LABEL+="${LEVELS_LABEL:+,}$zone=$pair"
    list+="$(sha256sum "$ctx/etc/levels/$zone/level-manifest.json" | cut -d' ' -f1)  /etc/riftal/levels/$zone/level-manifest.json"$'\n'
  done
  if [ -z "$LEVELS_LABEL" ]; then
    printf '::error::%s holds no <zone>.lock.json, and the image would carry no level\n' "$locks"
    return 1
  fi

  for name in "${BOOT_SCRIPTS[@]}"; do
    cp "$SCRIPT_DIR/../images/plugins/$name" "$ctx/boot/$name"
    chmod 0555 "$ctx/boot/$name"
  done
  printf '%s' "$list" >"$ctx/boot/etc-riftal.sha256"
  chmod 0444 "$ctx/boot/etc-riftal.sha256"
  find "$ctx/etc" -type d -exec chmod 0755 {} +
  find "$ctx/etc" -type f -exec chmod 0444 {} +
}

# $1 an item, then a list. Succeeds when the item is in the list.
in_list() {
  local item="$1" entry
  shift
  for entry in "$@"; do
    [ "$entry" = "$item" ] && return 0
  done
  return 1
}

# $1 a checkout root. Prints an ::error:: for each top-level .sh of deploy/,
# migrations/ and images/ that is on neither list or on both, and for each
# HOST_SCRIPTS entry the checkout lacks. Returns 1 when it printed any.
classify_scripts() {
  local root="$1" path rel bad=0
  for path in "$root"/deploy/*.sh "$root"/migrations/*.sh "$root"/images/*.sh; do
    rel="${path#"$root"/}"
    if in_list "$rel" "${HOST_SCRIPTS[@]}" && in_list "$rel" "${NOT_CARRIED_SCRIPTS[@]}"; then
      printf '::error::%s is on both the host list and the not-carried list in release-image.sh\n' "$rel"
      bad=1
    elif ! in_list "$rel" "${HOST_SCRIPTS[@]}" && ! in_list "$rel" "${NOT_CARRIED_SCRIPTS[@]}"; then
      printf '::error::%s is on neither the host list nor the not-carried list in release-image.sh; put it on one\n' "$rel"
      bad=1
    fi
  done
  for rel in "${HOST_SCRIPTS[@]}"; do
    if [ ! -f "$root/$rel" ]; then
      printf '::error::%s is on the host list and is not in the checkout\n' "$rel"
      bad=1
    fi
  done
  return "$bad"
}

# $1 the ops image's build context, $2 MIGRATIONS_DIR, $3 GRANTS_SQL. Lays out
# ops/, sql/ and ops.sha256 in it, files 0444, scripts 0555 and directories
# 0755, and sets MIGRATIONS_SHA and OPS_SHA to what the labels hold. The locks
# are those of the levels bake_levels baked.
bake_ops() {
  local ctx="$1" migrations="$2" grants="$3" root="$SCRIPT_DIR/.." src rel
  local locks="${LEVEL_LOCKS_DIR:-$SCRIPT_DIR/../designer/levels}"
  mkdir -p "$ctx/ops/designer/levels" "$ctx/sql/migrations"
  for src in "${HOST_SCRIPTS[@]/#/$root/}" "$root/deploy/write-latency-probe.php" "$root"/deploy/*.md \
    "$root/migrations/README.md" "$root/images/README.md"; do
    rel="${src#"$root"/}"
    mkdir -p "$ctx/ops/${rel%/*}"
    cp "$src" "$ctx/ops/$rel"
  done
  cp "$locks"/*.lock.json "$ctx/ops/designer/levels/"
  cp "$migrations"/*.sql "$ctx/sql/migrations/"
  cp "$grants" "$ctx/sql/grants.sql"
  find "$ctx" -type d -exec chmod 0755 {} +
  find "$ctx" -type f -exec chmod 0444 {} +
  find "$ctx/ops" -type f -name '*.sh' -exec chmod 0555 {} +
  MIGRATIONS_SHA="$(tree_sha256 "$ctx/sql/migrations")"
  (cd "$ctx" && find ops sql -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum -- >ops.sha256)
  chmod 0444 "$ctx/ops.sha256"
  OPS_SHA="$(sha256sum "$ctx/ops.sha256" | cut -d' ' -f1)"
}

main() {
  local phars="${1:?usage: release-image.sh <directory holding the built phars>}"
  local image="${RELEASE_IMAGE:-riftal/pocketmine-mp}"
  local backup_image="${BACKUP_IMAGE:-riftal/backup}"
  local date="${RELEASE_DATE:-$(date -u +%F)}"
  local name tag ref bref base ctx bctx sums="" scripts="" id bid
  local commit="${GAME_COMMIT:-}" grants="${GRANTS_SQL:-}" migrations="${MIGRATIONS_DIR:-}" grants_sha infra

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
  if [ ! -d "$migrations" ] || ! compgen -G "$migrations/*.sql" >/dev/null; then
    printf '::error::MIGRATIONS_DIR "%s" is not a directory holding a .sql file; the ops image carries them\n' "$migrations"
    return 1
  fi

  infra="$(infra_commit "$SCRIPT_DIR/.." 2>&1)" || {
    printf '::error::%s\n' "$infra"
    return 1
  }
  classify_scripts "$SCRIPT_DIR/.." || return 1

  core_image || return 1
  tag="$(release_tag "$date" "${CORE_IMAGE#*:}" "$commit" "$infra")" || return 1
  ref="$image:$tag"
  bref="$backup_image:$tag"

  for name in "$ref" "$bref"; do
    if docker image inspect "$name" >/dev/null 2>&1; then
      printf '::error::%s already exists; a release tag is immutable and is never rebuilt\n' "$name"
      return 1
    fi
  done

  ctx="$(mktemp -d)"
  bctx="$(mktemp -d)"
  trap 'chmod -R u+rwX "$ctx" "$bctx" 2>/dev/null; rm -rf "$ctx" "$bctx"' RETURN
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
  bake_ops "$bctx" "$migrations" "$grants" || return 1
  cp "$SCRIPT_DIR/../images/release/Dockerfile.backup" "$bctx/Dockerfile"

  base="$backup_image-base:$tag"
  docker build -t "$base" "$SCRIPT_DIR/../images/backup" || return 1
  docker build \
    --build-arg "BACKUP_BASE=$base" \
    --label "org.riftal.infra-commit=$infra" \
    --label "org.riftal.game-commit=$commit" \
    --label "org.riftal.grants-sha256=$grants_sha" \
    --label "org.riftal.migrations-sha256=$MIGRATIONS_SHA" \
    --label "org.riftal.ops-sha256=$OPS_SHA" \
    -t "$bref" "$bctx" || return 1
  docker image rm "$base" >/dev/null
  bid="$(docker image inspect --format '{{.Id}}' "$bref")" || return 1

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
    --label "org.riftal.backup-image=$bid" \
    -t "$ref" "$ctx" || {
    docker image rm "$bref" >/dev/null 2>&1
    return 1
  }

  id="$(docker image inspect --format '{{.Id}}' "$ref")" || return 1
  printf 'ops image %s (%s)\n' "$bref" "$bid"
  printf 'release image %s (%s) built from %s\n' "$ref" "$id" "$CORE_IMAGE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
