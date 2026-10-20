#!/usr/bin/env bash
# Refuses a grants.sql whose REVOKE statements are new against a tag that can
# still run (riftal-infra#944, riftal-pm ADR 008 item 3). /deploy-release stage
# 1 applies grants.sql before stage 2 rolls instances one at a time, so a REVOKE
# applied while an instance still runs the previous tag takes a privilege that
# instance still needs. It reads and lists containers and reads files, and
# stops, starts and changes nothing.
#
#   grants-revoke-check.sh <new-grants.sql> <release-tag> [<tag>=<grants.sql> ...]
#
# Each <tag>=<file> names the grants.sql of the riftal-game commit that tag's
# plugins were built from. Nothing records that mapping yet, so the operator
# supplies it, and a tag in use with no mapping is a refusal, never a pass.
# Every tag in use other than <release-tag> is checked, so no ordering of tags
# is needed and no tag older than the oldest is skipped.
#
# A tag is in use when it is named by (ADR 006's balance snapshot "When", all three):
#   - a running container,
#   - a stopped container,
#   - a file under INSTANCES_DIR.
#
# Environment:
#   INSTANCE_IMAGE     required, the image name without its tag
#   CONTAINER_RUNTIME  default docker; may carry arguments, for example
#                      "wsl -d Ubuntu-26.04 -u runner --exec docker"
#   INSTANCES_DIR      default ../instances
#
#     0  one GRANTS REVOKE OK line
#     1  one GRANTS REVOKE REFUSED line per new REVOKE and tag
#     2  usage, an unreadable file, a runtime that failed, an image whose tag
#        cannot be read, or a tag in use with no grants.sql; never a pass
#
# REVOKE statements compare after dropping -- comments and collapsing
# whitespace. Anything else about a statement counts as a different statement,
# which errs toward refusing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${INSTANCES_DIR:-$SCRIPT_DIR/../instances}"
read -r -a runtime <<<"${CONTAINER_RUNTIME:-docker}"

die() {
  echo "grants-revoke-check.sh: $1" >&2
  exit 2
}

if [ "$#" -lt 2 ]; then
  die 'usage: grants-revoke-check.sh <new-grants.sql> <release-tag> [<tag>=<grants.sql> ...]'
fi
[ -n "${INSTANCE_IMAGE:-}" ] || die 'INSTANCE_IMAGE is not set'
new_grants="$1"
release_tag="$2"
shift 2

readable() { [ -f "$1" ] && [ -r "$1" ]; }

declare -A baseline=()
for pair in "$@"; do
  tag="${pair%%=*}"
  file="${pair#*=}"
  if [ "$tag" = "$pair" ] || [ -z "$tag" ] || [ -z "$file" ]; then
    die "'$pair' is not <tag>=<grants.sql>"
  fi
  baseline[$tag]="$file"
done

readable "$new_grants" || die "cannot read $new_grants"
[ -d "$INSTANCES_DIR" ] || die "cannot read instance definitions in $INSTANCES_DIR"

revokes() {
  sed -e 's/--.*$//' "$1" | tr '\n\r\t' '   ' | tr -s ' ' | tr ';' '\n' |
    sed -e 's/^ //' -e 's/ $//' |
    { grep -i -E '^REVOKE( |$)' || [ "$?" -eq 1 ]; }
}

declare -A used=()
# note_image <image> <where it was found>; images of other repositories are
# not ours and are skipped.
note_image() {
  local image="$1" src="$2" tag
  if [[ $image =~ ^(sha256:)?[0-9a-f]{12,64}$ ]]; then
    die "$src runs an image known only by id $image, so its tag cannot be read"
  fi
  case "$image" in
    "$INSTANCE_IMAGE":*) tag="${image#"$INSTANCE_IMAGE":}" ;;
    "$INSTANCE_IMAGE" | "$INSTANCE_IMAGE"@*) die "$src names $image with no tag" ;;
    *) return 0 ;;
  esac
  if [ -z "$tag" ] || [ "$tag" = latest ] || [[ $tag == *@* ]]; then
    die "$src names $image, which is not an immutable tag"
  fi
  used[$tag]="${used[$tag]:+${used[$tag]}, }$src"
}

list_containers() {
  "${runtime[@]}" "$@" --format '{{.Names}}	{{.Image}}' || die "'${runtime[*]} $*' failed"
}

running="$(list_containers ps)"
all="$(list_containers ps -a)"
declare -A is_running=()
while IFS=$'\t' read -r name image; do
  [ -n "$name" ] || continue
  is_running[$name]=1
  note_image "$image" "running container $name"
done <<<"$running"
while IFS=$'\t' read -r name image; do
  [ -n "$name" ] || continue
  [ -z "${is_running[$name]:-}" ] || continue
  note_image "$image" "stopped container $name"
done <<<"$all"

while IFS= read -r -d '' def; do
  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    while [[ $line == *"$INSTANCE_IMAGE"* ]]; do
      rest="${line#*"$INSTANCE_IMAGE"}"
      token="${rest%%[[:space:]\"\']*}"
      note_image "$INSTANCE_IMAGE$token" "instance definition $def:$line_no"
      line="$rest"
    done
  done <"$def"
done < <(find "$INSTANCES_DIR" -type f -print0 | sort -z)

checked=0
missing=0
for tag in "${!used[@]}"; do
  [ "$tag" != "$release_tag" ] || continue
  if [ -z "${baseline[$tag]:-}" ]; then
    echo "grants-revoke-check.sh: tag $tag (${used[$tag]}) has no <tag>=<grants.sql>, so what it ran against cannot be determined" >&2
    missing=1
  elif ! readable "${baseline[$tag]}"; then
    echo "grants-revoke-check.sh: cannot read ${baseline[$tag]} for tag $tag" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 2

mapfile -t new_revokes < <(revokes "$new_grants")
refused=0
for tag in $(printf '%s\n' "${!used[@]}" | sort); do
  [ "$tag" != "$release_tag" ] || continue
  checked=$((checked + 1))
  declare -A have=()
  while IFS= read -r old; do
    [ -z "$old" ] || have[$old]=1
  done < <(revokes "${baseline[$tag]}")
  for stmt in "${new_revokes[@]}"; do
    [ -n "$stmt" ] || continue
    if [ -z "${have[$stmt]:-}" ]; then
      printf 'GRANTS REVOKE REFUSED: "%s" is new against tag %s (%s)\n' "$stmt" "$tag" "${used[$tag]}"
      refused=1
    fi
  done
  unset have
done

if [ "$refused" -ne 0 ]; then
  exit 1
fi
printf 'GRANTS REVOKE OK: %s REVOKE statement(s) in %s, %s older tag(s) checked\n' \
  "${#new_revokes[@]}" "$new_grants" "$checked"
