#!/usr/bin/env bash
# The volume half of a wipe. wipe.sh sources this and calls wipe_volumes once
# the database is found and idle and before the drop. On every instance volume
# under WORLDS_DIR it clears an explicit list of paths and nothing else
# (steward, riftal-pm#696 and riftal-infra#1123): each level folder under
# worlds/, and what players/ and plugin_data/ hold. Logs, crash dumps, the op
# and white lists, the ban lists, and anything else on the volume stay byte for
# byte. RiftalCapture empties .capture/ itself when it enables.
#
# Every check runs on every volume before anything is cleared, so a refusal
# leaves every volume as it was. A failure after the first clear is not a
# refusal: the seed step failing to copy or write is one, and a clear that
# stops part way is another. The database is intact and some or all volumes
# are cleared, so any non-zero exit with no "refused:" line is a rollback.
#
# The one argument is the dev verdict wipe.sh computes once per run: "dev", or
# the reason the stack is not dev (riftal-pm#1314). A level with no ADR 009
# build is cleared and left absent only on dev. A level with a build is cleared
# and re-seeded from its build's output folder, LEVEL_BUILDS_DIR/<zone>, by
# images/plugins/seed-levels.sh, on any stack. The folder is checked against the
# lock's content_sha256 and its own tree hash before anything is cleared, and the
# seed step's zone-name and file-type checks are made then too. Every volume is
# cleared before any is re-seeded; the backup set rolls a failed re-seed back.

# Run on its own, this would skip every check wipe.sh makes and take the dev
# verdict from whoever typed it, so it defines nothing and clears nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "wipe: refused: wipe-volumes.sh runs only inside wipe.sh, after its checks; run wipe.sh" >&2
  exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/wipe-lib.sh"

# Uses wipe.sh's fail, so a refusal here exits the whole wipe before the drop.
wipe_volumes() {
  local dev="$1" volume name level zone dir count tar_file lock build want seed owner
  local volumes=() levels=() reseed_volumes=() reseed_zones=() i
  seed="${SEED_LEVELS_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/../images/plugins/seed-levels.sh}"
  [ -n "${WORLDS_DIR:-}" ] || fail "WORLDS_DIR is required: the directory every instance volume is mounted under, as for backup.sh"
  [ -n "${LEVEL_LOCKS_DIR:-}" ] && [ -d "$LEVEL_LOCKS_DIR" ] \
    || fail "LEVEL_LOCKS_DIR must name a directory: designer/levels, which holds each ADR 009 build's <zone>.lock.json"

  # Volumes are found the way backup.sh finds them, so each has its tar.
  shopt -s nullglob
  volumes=("$WORLDS_DIR"/*/)
  [ "${#volumes[@]}" -gt 0 ] || fail "no instance volumes found under $WORLDS_DIR"

  # The set is the rollback, and a volume missing from WORLDS_DIR is one the
  # wipe would leave holding the last alpha's items.
  for tar_file in "$BACKUP_SET"/worlds/*.tar.gz; do
    [ -d "$WORLDS_DIR/$(basename "$tar_file" .tar.gz)" ] \
      || fail "$tar_file has no volume under $WORLDS_DIR, so that volume would not be wiped"
  done

  # dotglob here, so a level whose name starts with a dot is checked and cleared.
  shopt -s dotglob
  for volume in "${volumes[@]}"; do
    name="$(basename "$volume")"
    [ -f "$BACKUP_SET/worlds/$name.tar.gz" ] \
      || fail "$BACKUP_SET holds no $name.tar.gz, so restore.sh could not roll volume $name back"
    for level in "$volume"worlds/*/; do
      zone="$(basename "$level")"
      lock="$LEVEL_LOCKS_DIR/$zone.lock.json"
      if [ -e "$lock" ]; then
        [[ "$zone" =~ ^[A-Za-z0-9_-]+$ ]] \
          || fail "level $zone on $name has an ADR 009 build, and the seed step takes only letters, digits, _ and - in a zone name"
        build="${LEVEL_BUILDS_DIR:-}/$zone"
        [ -n "${LEVEL_BUILDS_DIR:-}" ] && [ -f "$build/level-manifest.json" ] \
          || fail "level $zone on $name has an ADR 009 build to re-seed from, and LEVEL_BUILDS_DIR must hold its output folder $zone with a level-manifest.json"
        want="$(json_digest "$lock" content_sha256)"
        [ -n "$want" ] && [ "$want" = "$(json_digest "$build/level-manifest.json" content_sha256)" ] \
          || fail "$build/level-manifest.json does not carry content_sha256 $want, the one in $lock"
        odd="$(find "$build" ! -type f ! -type d -print -quit)"
        [ -z "$odd" ] || fail "$odd is neither a regular file nor a directory, and the seed step refuses a build that holds one"
        [ "$(tree_sha256 "$build")" = "$(json_digest "$build/level-manifest.json" tree_sha256)" ] \
          || fail "the file tree of $build is not the one its level-manifest.json names"
        [ -f "$seed" ] || fail "$seed is not there; mount images/plugins beside deploy/"
        [ "$(stat -c %u "${volume}worlds")" != 0 ] \
          || fail "${volume}worlds is owned by root, so core could not write the re-seeded level $zone"
        reseed_volumes+=("$volume")
        reseed_zones+=("$zone")
      else
        [ "$dev" = dev ] \
          || fail "level $zone on $name has no ADR 009 build, and a wipe clears one only on the dev stack: $dev"
      fi
      levels+=("${level%/}")
    done
  done
  shopt -u nullglob dotglob

  for level in "${levels[@]}"; do
    rm -rf -- "$level"
  done
  for volume in "${volumes[@]}"; do
    name="$(basename "$volume")"
    # The folders themselves stay, so they keep the owner core writes them as.
    for dir in players plugin_data; do
      if [ -d "$volume$dir" ]; then
        find "$volume$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
      fi
    done
    count=0
    for level in "${levels[@]}"; do
      [[ "$level" != "$volume"* ]] || count=$((count + 1))
    done
    echo "wipe $MYSQL_DATABASE: volume $name: cleared $count level(s) and the contents of players/ and plugin_data/"
  done

  # Every volume is cleared before any is re-seeded, so a copy or I/O failure
  # here leaves every volume in the same state, never half old and half new.
  for i in "${!reseed_zones[@]}"; do
    volume="${reseed_volumes[$i]}"
    zone="${reseed_zones[$i]}"
    name="$(basename "$volume")"
    owner="$(stat -c %u:%g "${volume}worlds")"
    if ! RIFTAL_LEVEL_ZONES="$zone" RIFTAL_LEVELS_DIR="$LEVEL_BUILDS_DIR" RIFTAL_WORLDS_DIR="${volume}worlds" \
      RIFTAL_SEED_CHOWN="$owner" bash "$seed" true; then
      echo "wipe $MYSQL_DATABASE: FAILED, not refused: the seed step stopped on level $zone after every volume was cleared; the database is intact, the volumes are not: run restore.sh with the step 3 set (WIPE.md, Rollback)" >&2
      exit 1
    fi
    echo "wipe $MYSQL_DATABASE: volume $name: re-seeded level $zone from $LEVEL_BUILDS_DIR/$zone"
  done
}
