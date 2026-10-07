#!/usr/bin/env bash
# Runs one scan over the real tree: `dockerfiles` or `compose`.
#
# The self-test drives this exact script, with no root or prune argument, the
# same way ci.yml calls it below, so discovery, dispatch, the two check_
# functions and the loop are all exercised by what gates a merge, not by a
# copy of them.
set -euo pipefail

kind="${1:?usage: scan.sh <dockerfiles|compose> [root] [prune-path]}"
root="${2:-.}"
prune="${3:-$root/.github/ci-fixtures}"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_dockerfiles() { "$HADOLINT" "$1"; }
check_compose() { docker compose -f "$1" config --quiet; }

# Command substitution puts discovery's exit status under `set -e`, so a
# discovery that dies stops the scan instead of reading as an empty tree.
# LISTER is how the self-test makes discovery fail on demand.
#
# HADOLINT has no default. A bare `hadolint` would be a PATH lookup, which on
# the self-hosted runner can find a binary in a directory every job can write,
# instead of the one install-hadolint.sh checked for this job.
case "$kind" in
  dockerfiles) label='Dockerfile(s)/Containerfile(s)'
    : "${HADOLINT:?HADOLINT must name the hadolint binary to run}"
    found="$(find "$root" -path "$root/.git" -prune -o -path "$prune" -prune -o \
      -type f \( -name Dockerfile -o -name 'Dockerfile.*' \
        -o -name '*.Dockerfile' -o -name Containerfile \
        -o -name 'Containerfile.*' -o -name '*.Containerfile' \) -print)" ;;
  compose) label='compose file(s)'
    found="$(bash "${LISTER:-$scripts/list_compose.sh}" "$root" "$prune")" ;;
  *) printf 'unknown scan: %s\n' "$kind" >&2; exit 2 ;;
esac

mapfile -t files < <(printf '%s' "$found")
printf 'found %d %s outside the fixtures\n' "${#files[@]}" "$label"
if [ "${#files[@]}" -eq 0 ]; then
  printf 'nothing to check yet in this tree\n'
  exit 0
fi

status=0
for file in "${files[@]}"; do
  printf 'checking %s\n' "$file"
  "check_$kind" "$file" || status=1
done
exit "$status"
