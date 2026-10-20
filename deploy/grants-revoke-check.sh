#!/usr/bin/env bash
# Refuses a grants.sql whose REVOKE statements are new against a tag that can
# still run (riftal-infra#944, riftal-pm ADR 008 item 3). /deploy-release stage
# 1 applies grants.sql before stage 2 rolls instances one at a time, so a REVOKE
# applied while an instance still runs the previous tag takes a privilege that
# instance still needs. It only reads files and lists containers.
#
#   grants-revoke-check.sh <new-grants.sql> <release-tag> [<tag>=<grants.sql> ...]
#
# Each <tag>=<file> names the grants.sql that tag's plugins were built from.
# Nothing records that mapping yet, so the operator supplies it, and a tag in
# use with no mapping is a refusal, never a pass. Every tag in use other than
# <release-tag> is checked against its own file. A tag is in use when a running
# container, a stopped container or a file under INSTANCES_DIR names it (ADR
# 006's balance snapshot "When").
#
# Environment:
#   INSTANCE_IMAGE     required, the image name without its tag
#   CONTAINER_RUNTIME  default docker; may carry arguments
#   INSTANCES_DIR      default instances/ beside deploy/, not the working directory
#
# Exit status: 0 one GRANTS REVOKE OK line; 1 one GRANTS REVOKE REFUSED line per
# new REVOKE and tag; 2 usage, an unreadable file or instance definition, a
# failed definition scan, a file outside the dialect below, a failed runtime, an
# image whose tag cannot be read, or a tag in use with no grants.sql. Never a
# pass on 2.
#
# The reader accepts one dialect, the one riftal-game lib/resources/sql/
# grants.sql is written in, and exits 2 naming the file and line on anything
# else. Outside a -- comment a file holds only letters, digits, underscore,
# comma, parentheses, semicolon, space, tab, CR and LF, and every statement
# begins with CREATE ROLE, GRANT or REVOKE. A -- must be followed by whitespace
# or the end of the line, and no byte may be other than printable ASCII, tab,
# CR or LF. So no # or /* */ comment, quote, backtick, backslash, DROP or
# client command is ever read, and none can hide or stand in for a REVOKE.
#
# A pass does not cover:
#   - more than one runtime: containers are listed from the one
#     CONTAINER_RUNTIME given, so run the check once per runtime that runs
#     instances;
#   - an image under any reference other than INSTANCE_IMAGE: it must be the
#     exact reference the runtime reports, or those containers are not seen;
#   - a REVOKE the older file later undoes: statements compare as a set of
#     texts with whitespace collapsed, so a REVOKE the older file follows with
#     a GRANT of the same privilege still counts as carried.
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
  local at
  at="$(export LC_ALL=C; grep -a -n -m1 -o "[^[:print:]"$'\t\r'"]" "$1" | sed -n '1{s/:.*//;p;q}' || true)"
  if [ -n "$at" ]; then
    echo "grants-revoke-check.sh: $1:$at: a byte other than printable ASCII, tab, CR or LF, which the reader does not handle" >&2
    return 2
  fi
  LC_ALL=C awk '
    function bad(line, why) {
      printf "grants-revoke-check.sh: %s:%d: %s, which the reader does not handle\n", FILENAME, line, why > "/dev/stderr"
      failed = 1
    }
    function finish(   t) {
      t = stmt; gsub(/[ \t\r]+/, " ", t); gsub(/^ | $/, "", t); stmt = ""
      if (t == "") return
      if (tolower(t) !~ /^(create role|grant|revoke)( |$)/) bad(first, "a statement that does not begin with CREATE ROLE, GRANT or REVOKE")
      else if (tolower(t) ~ /^revoke/) print t
    }
    {
      i = index($0, "--"); pre = i ? substr($0, 1, i - 1) : $0
      if (i && substr($0, i + 2, 1) ~ /[^ \t\r]/) bad(NR, "a -- not followed by whitespace")
      if (pre ~ /[^A-Za-z0-9_,(); \t\r]/) bad(NR, "a character outside letters, digits, _ , ( ) ; and whitespace")
      n = split(pre, part, ";")
      for (k = 1; k <= n; k++) {
        if (stmt ~ /^[ \t\r]*$/ && part[k] ~ /[^ \t\r]/) first = NR
        stmt = stmt " " part[k]
        if (k < n) finish()
      }
    }
    END { finish(); if (failed) exit 2 }' "$1"
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

defs="$(find "$INSTANCES_DIR" -type f | sort)" || die "cannot scan instance definitions in $INSTANCES_DIR"
while IFS= read -r def; do
  [ -n "$def" ] || continue
  readable "$def" || die "cannot read instance definition $def"
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
done <<<"$defs"

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
