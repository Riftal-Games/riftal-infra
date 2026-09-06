#!/usr/bin/env bash
# Runs one scan over the real tree: `dockerfiles` or `compose`.
#
# Discovery and dispatch below are the code the self-test proves can fail. The
# two check_ functions and the loop calling them are proven by nothing: the
# self-test drives its own copies of them. riftal-infra#23 closes the gap.
set -euo pipefail

kind="${1:?usage: scan.sh <dockerfiles|compose> [root] [prune-path]}"
root="${2:-.}"
prune="${3:-$root/.github/ci-fixtures}"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_dockerfiles() { "${HADOLINT:-hadolint}" "$1"; }
check_compose() { docker compose -f "$1" config --quiet; }

# Command substitution puts discovery's exit status under `set -e`, so a
# discovery that dies stops the scan instead of reading as an empty tree.
# LISTER is how the self-test makes discovery fail on demand.
case "$kind" in
  dockerfiles) label='Dockerfile(s)'
    found="$(find "$root" -path "$root/.git" -prune -o -path "$prune" -prune -o \
      -type f \( -name Dockerfile -o -name 'Dockerfile.*' \
        -o -name '*.Dockerfile' \) -print)" ;;
  compose) label='compose file(s)'
    found="$(bash "${LISTER:-$scripts/list_compose.sh}" "$root" "$prune")" ;;
  *) printf 'unknown scan: %s\n' "$kind" >&2; exit 2 ;;
esac

mapfile -t files < <(printf '%s' "$found")
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
