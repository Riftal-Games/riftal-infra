#!/usr/bin/env bash
# Read by wipe-volumes.sh and wipe-check.sh, which source it. It defines
# functions and runs nothing. Both read a built level the way
# images/plugins/seed-levels.sh does, so a level that script seeded is judged by
# the digests it checked.

# json_digest <file> <key> prints the one 64-digit hex value written on its own
# line as "<key>": "...", and nothing when the key is missing or repeated.
json_digest() {
  local found
  found="$(sed -n "s/^ *\"$2\": *\"\\([0-9a-f]\\{64\\}\\)\",\\{0,1\\} *\$/\\1/p" "$1" 2>/dev/null)"
  if [ "$(printf '%s' "$found" | grep -c .)" -eq 1 ]; then
    printf '%s' "$found"
  fi
}

# tree_sha256 <level folder> prints the sha256 of the sha256sum lines of every
# regular file but the root level-manifest.json, as seed-levels.sh computes it.
tree_sha256() {
  (
    cd "$1"
    find . -type f ! -path ./level-manifest.json -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum -- | sha256sum | cut -d' ' -f1
  )
}
