#!/usr/bin/env bash
# Runs one scan over the real tree: `dockerfiles` or `compose`.
#
# The workflow calls this rather than inlining the body, so the self-test drives
# the same code CI runs, failure paths included.
set -euo pipefail

kind="${1:?usage: scan.sh <dockerfiles|compose> [root] [prune-path]}"
root="${2:-.}"
prune="${3:-$root/.github/ci-fixtures}"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_dockerfiles() { hadolint "$1"; }
check_compose() { docker compose -f "$1" config --quiet; }

# Discovery is captured through a command substitution so `set -e` sees it fail.
# Read straight into `mapfile < <(...)` the status is mapfile's own, zero
# whatever discovery did, so a dead scan prints the `found 0` of an empty tree.
# LISTER is how the self-test makes discovery fail on demand.
case "$kind" in
  dockerfiles) label='Dockerfile(s)'
    mapfile -t files < <(find "$root" -path "$root/.git" -prune -o -path "$prune" -prune -o \
      -type f \( -name Dockerfile -o -name 'Dockerfile.*' \
        -o -name '*.Dockerfile' \) -print) ;;
  compose) label='compose file(s)'
    mapfile -t files < <(bash "${LISTER:-$scripts/list_compose.sh}" "$root" "$prune") ;;
  *) printf 'unknown scan: %s\n' "$kind" >&2; exit 2 ;;
esac

printf 'found %d %s outside the fixtures\n' "${#files[@]}" "$label"
if [ "${#files[@]}" -eq 0 ]; then
  printf 'nothing to check yet; the self-test is what proves this is wired\n'
  exit 0
fi

status=0
for file in "${files[@]}"; do
  printf 'checking %s\n' "$file"
  "check_$kind" "$file" || status=1
done
exit "$status"
