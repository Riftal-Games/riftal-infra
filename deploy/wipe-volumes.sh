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
# leaves every volume as it was.
#
# The one argument is the dev verdict wipe.sh computes once per run: "dev", or
# the reason the stack is not dev (riftal-pm#1314). A level with no ADR 009
# build is cleared and left absent only on dev. A level with a build must be
# re-seeded from it, which this does not do, so it refuses.

# Run on its own, this would skip every check wipe.sh makes and take the dev
# verdict from whoever typed it, so it defines nothing and clears nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "wipe: refused: wipe-volumes.sh runs only inside wipe.sh, after its checks; run wipe.sh" >&2
  exit 1
fi

# Uses wipe.sh's fail, so a refusal here exits the whole wipe before the drop.
wipe_volumes() {
  local dev="$1" volume name level zone dir count tar_file
  local volumes=() levels=()
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
      [ ! -e "$LEVEL_LOCKS_DIR/$zone.lock.json" ] \
        || fail "level $zone on $name has an ADR 009 build to re-seed from, and re-seed is riftal-infra#1126"
      [ "$dev" = dev ] \
        || fail "level $zone on $name has no ADR 009 build, and a wipe clears one only on the dev stack: $dev"
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
}
