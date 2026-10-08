#!/usr/bin/env bash
# Removes stale local-pocketmine-mp:<sha> tags from this runner's Docker
# daemon (riftal-infra#674 and the steward ruling on it). Every push of
# pmmp-core riftal tags one there, and a removed tag is rebuilt by re-running
# that push's Docker image CI.
#
# Candidates are only tags matching local-pocketmine-mp:<40 hex>, so the bare
# tag and every other repository are never touched. Kept: main's pin, the pin
# at the head of every open pull request, so a pull request that moves the pin
# is not turned red, and the 3 newest candidates by image Created.
#
# Fails closed: when main's pin does not resolve through core_image, or the
# open pull requests or any of their pin files cannot be read, nothing is
# removed and the exit status is 1. A pull request with no pin file or a
# malformed one adds nothing to the keep set.
#
# Each removal is a plain `docker image rm` of one tag. A tag Docker refuses is
# reported and left. Only a schedule or workflow_dispatch run of main removes;
# any other run prints what it would remove.
#
# $1 main's pin file, core-image.sha beside this script when omitted.
# GITHUB_REPOSITORY names the repository, GH_TOKEN reads its pull requests,
# GITHUB_API_URL is https://api.github.com when unset.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/core-image.sh"

NEWEST=3
# 30 pages of 100 open pull requests is far past anything this repository
# holds, so reaching it means the paging is broken, not that the list is long.
MAX_PAGES=30

abort() {
  printf '::error::%s, so nothing is removed\n' "$1"
  exit 1
}

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name the repository}"
: "${GH_TOKEN:?GH_TOKEN must hold a token that reads pull requests}"
api="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY"

work="$(mktemp -d)" || abort "cannot make a work directory under ${TMPDIR:-/tmp}"
trap 'rm -rf "$work"' EXIT

# $1 URL, $2 file the body goes to, $3 Accept type. Prints the HTTP status.
# The token goes in on stdin so it never shows in the process list.
get() {
  printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" |
    curl --config - -sS -o "$2" -w '%{http_code}' -H "Accept: $3" "$1"
}

remove=no
case "${GITHUB_EVENT_NAME:-}" in
  schedule | workflow_dispatch)
    [ "${GITHUB_REF:-}" = refs/heads/main ] && remove=yes
    ;;
esac

listed="$(docker image ls --format '{{.Repository}}:{{.Tag}}' local-pocketmine-mp)" ||
  abort "cannot list the local-pocketmine-mp images"
candidates=()
while IFS= read -r tag; do
  [[ "$tag" =~ ^local-pocketmine-mp:[0-9a-f]{40}$ ]] || continue
  created="$(docker image inspect --format '{{.Created}}' "$tag")" &&
    ns="$(date -u -d "$created" +%s%N)" ||
    abort "cannot read when $tag was created"
  candidates+=("$ns $tag")
done <<<"$listed"

declare -A keep
# $1 tag, $2 why it stays
keep_tag() {
  keep["$1"]="${keep[$1]:+${keep[$1]}, }$2"
}

core_image "${1:-$DIR/core-image.sha}" || abort "main's pin does not resolve"
keep_tag "$CORE_IMAGE" "main's images/core-image.sha"

prs=
page=1
while :; do
  if ! status="$(get "$api/pulls?state=open&per_page=100&page=$page" "$work/pulls" \
    application/vnd.github+json)" || [ "$status" != 200 ]; then
    abort "listing open pull requests answered ${status:-nothing}"
  fi
  count="$(jq -r 'length' "$work/pulls")" &&
    lines="$(jq -r '.[] | "\(.number) \(.head.sha)"' "$work/pulls")" ||
    abort "cannot read page $page of the open pull requests"
  prs+="$lines"$'\n'
  [ "$count" -lt 100 ] && break
  page=$((page + 1))
  [ "$page" -le "$MAX_PAGES" ] || abort "open pull requests run past $MAX_PAGES pages"
done

while read -r number head; do
  [ -n "$number" ] || continue
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || abort "pull request #$number has no head sha"
  status="$(get "$api/contents/images/core-image.sha?ref=$head" "$work/pin" \
    application/vnd.github.raw)" || status="a failed request ($status)"
  case "$status" in
    200)
      sha="$(tr -d '[:space:]' < "$work/pin")"
      if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        keep_tag "local-pocketmine-mp:$sha" "pull request #$number"
      else
        printf 'pull request #%s pins "%s", not a sha, so it keeps nothing\n' "$number" "$sha"
      fi
      ;;
    404)
      printf 'pull request #%s has no images/core-image.sha, so it keeps nothing\n' "$number"
      ;;
    *)
      abort "reading the pin of pull request #$number answered ${status:-nothing}"
      ;;
  esac
done <<<"$prs"

newest=0
if [ "${#candidates[@]}" -gt 0 ]; then
  while read -r _ tag; do
    newest=$((newest + 1))
    [ "$newest" -le "$NEWEST" ] && keep_tag "$tag" "one of the $NEWEST newest"
  done < <(printf '%s\n' "${candidates[@]}" | sort -rn)
fi

for tag in "${!keep[@]}"; do
  printf 'keep %s: %s\n' "$tag" "${keep[$tag]}"
done | sort

for line in "${candidates[@]}"; do
  tag="${line#* }"
  [ -n "${keep[$tag]:-}" ] && continue
  if [ "$remove" != yes ]; then
    printf 'would remove %s; only a schedule or dispatch run of main removes\n' "$tag"
  elif docker image rm "$tag"; then
    printf 'removed %s\n' "$tag"
  else
    printf '::warning::Docker refused to remove %s, so it stays\n' "$tag"
  fi
done
