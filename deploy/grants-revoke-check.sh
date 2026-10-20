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
# A tag is in use when any one of these names it (ADR 006's balance snapshot
# "When"):
#   - a running container,
#   - a stopped container,
#   - a file under INSTANCES_DIR.
#
# Containers are listed from the one CONTAINER_RUNTIME given, so a pass covers
# that runtime only. ADR 006 requires no older-tag container on any machine, so
# run the check once per machine that runs instances, each with its own runtime.
#
# Environment:
#   INSTANCE_IMAGE     required, the image name without its tag
#   CONTAINER_RUNTIME  default docker; may carry arguments, for example
#                      "wsl -d Ubuntu-26.04 -u runner --exec docker"
#   INSTANCES_DIR      default instances/ beside deploy/, not the working directory
#
# Exit status:
#     0  one GRANTS REVOKE OK line
#     1  one GRANTS REVOKE REFUSED line per new REVOKE and tag
#     2  usage, an unreadable file, a file the reader cannot handle (below), a
#        runtime that failed, an image whose tag cannot be read, or a tag in use
#        with no grants.sql; never a pass
#
# A statement containing the word REVOKE anywhere is a REVOKE, so one that
# follows a /* */ or # comment is still seen. They compare after dropping --
# comments and collapsing whitespace. Anything else about a statement, a /* */
# or # comment included, counts as a different statement, which errs toward
# refusing.
#
# The reader is not a SQL parser. Rather than guess where MySQL ends a comment
# or a string, it exits 2 on a file with any byte but printable ASCII, tab, CR
# or LF, a quote or backtick outside a -- comment, a -- not followed by
# whitespace, or a /* */ comment that spans lines or shares a line with a --.
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

declare -A baseline=() old_revokes=()
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
  if LC_ALL=C grep -a -q "[^[:print:]"$'\t\r'"]" "$1"; then
    echo "grants-revoke-check.sh: $1 has a byte other than printable ASCII, tab, CR or LF, which the reader does not handle" >&2
    return 2
  fi
  LC_ALL=C awk '
    function bad(why) {
      printf "grants-revoke-check.sh: %s:%d: %s, which the reader does not handle\n", FILENAME, NR, why > "/dev/stderr"
      failed = 1
    }
    {
      i = index($0, "--"); pre = i ? substr($0, 1, i - 1) : $0
      if (i && substr($0, i + 2, 1) ~ /[^ \t\r]/) bad("a -- not followed by whitespace")
      if (pre ~ /[\047"`]/) bad("a quote or backtick")
      s = pre; open = block = 0
      while ((p = index(s, open ? "*/" : "/*")) > 0) { block = 1; open = !open; s = substr(s, p + 2) }
      if (open || (block && i)) bad("a /* */ comment that spans lines or shares a line with --")
      text = text " " pre
    }
    END {
      if (failed) exit 2
      n = split(text, st, ";")
      for (k = 1; k <= n; k++) {
        t = st[k]; gsub(/[ \t\r]+/, " ", t); gsub(/^ | $/, "", t)
        if (tolower(t) ~ /(^|[^a-z0-9_])revoke([^a-z0-9_]|$)/) print t
      }
    }' "$1"
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
  else
    old_revokes[$tag]="$(revokes "${baseline[$tag]}")" || missing=1
  fi
done
new_text="$(revokes "$new_grants")" || missing=1
[ "$missing" -eq 0 ] || exit 2

new_revokes=()
[ -z "$new_text" ] || mapfile -t new_revokes <<<"$new_text"
refused=0
for tag in $(printf '%s\n' "${!used[@]}" | sort); do
  [ "$tag" != "$release_tag" ] || continue
  checked=$((checked + 1))
  declare -A have=()
  while IFS= read -r old; do
    [ -z "$old" ] || have[$old]=1
  done <<<"${old_revokes[$tag]}"
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
in_use="$(printf '%s\n' "${!used[@]}" | sort | paste -sd ' ' -)"
printf 'GRANTS REVOKE OK: %s REVOKE statement(s) in %s, %s older tag(s) checked, tags in use: %s, runtime: %s\n' \
  "${#new_revokes[@]}" "$new_grants" "$checked" "${in_use:-none}" "${runtime[*]}"
