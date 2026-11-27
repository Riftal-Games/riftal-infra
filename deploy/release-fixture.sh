#!/usr/bin/env bash
# Sourced by release-image-selftest.sh and release-start-selftest.sh, never
# run. Builds the fixtures a release image is baked from: level build volumes
# holding a manifest, and the zone locks naming them. Needs CORE_IMAGE set by
# core_image, since every volume is written through the pinned core image.

# $1 a volume, $2 the content_sha256 to record. Writes level-manifest.json at
# the root of the volume, its tree_sha256 over every other file in it, in the
# format designer level build writes.
fixture_manifest() {
  docker run --rm -m 1g --cpus 1 --network none --user root -v "$1:/level" -e "CONTENT=$2" \
    --entrypoint bash "$CORE_IMAGE" -c '
      set -euo pipefail
      cd /level
      rm -f level-manifest.json
      tree="$(find . -type f -printf "%P\0" | LC_ALL=C sort -z | xargs -0 -r sha256sum -- | sha256sum | cut -d" " -f1)"
      printf "{\n  \"content_sha256\": \"%s\",\n  \"tree_sha256\": \"%s\"\n}\n" "$CONTENT" "$tree" >level-manifest.json
      chmod -R a+rX .'
}

# $1 a volume, $2 the zone. Fills it with a small folder tree of its own.
fixture_tree() {
  docker run --rm -m 1g --cpus 1 --network none --user root -v "$1:/level" -e "ZONE=$2" \
    --entrypoint bash "$CORE_IMAGE" -c '
      set -euo pipefail
      mkdir -p /level/db/nested
      printf "level %s\n" "$ZONE" >/level/level.dat
      printf "table %s\n" "$ZONE" >/level/db/000001.ldb
      printf "deep %s\n" "$ZONE" >/level/db/nested/file'
}

# $1 the locks directory, $2 zone, $3 content_sha256, $4 core_image.
fixture_lock() {
  printf '{"zone": "%s", "content_sha256": "%s", "core_image": "%s"}\n' "$2" "$3" "$4" >"$1/$2.lock.json"
}
