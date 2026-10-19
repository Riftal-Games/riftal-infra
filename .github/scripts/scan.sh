#!/usr/bin/env bash
# Runs one scan over the real tree: `dockerfiles`, `compose` or `ports`.
#
# The self-test drives this exact script, with no root or prune argument, the
# same way ci.yml calls it below, so discovery, dispatch, every check_
# function and the loop are all exercised by what gates a merge, not by a
# copy of them.
set -euo pipefail

kind="${1:?usage: scan.sh <dockerfiles|compose|ports> [root] [prune-path]}"
root="${2:-.}"
prune="${3:-$root/.github/ci-fixtures}"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_dockerfiles() { "$HADOLINT" "$1"; }
check_compose() { docker compose -f "$1" config --quiet; }

# Every profile, because `config` drops a service behind a profile nobody
# asked for, and a publish nobody reads passes.
check_ports() {
  docker compose --profile '*' -f "$1" config --format json |
    python3 "$scripts/check_port_policy.py" "$1"
}

# Command substitution puts discovery's exit status under `set -e`, so a
# discovery that dies stops the scan instead of reading as an empty tree.
# LISTER is how the self-test makes discovery fail on demand.
#
# Both kinds list in LC_ALL=C order, the order list_compose.sh uses, so a log
# from one machine diffs cleanly against a log from another. find(1) alone
# gives directory order, which differs between filesystems and between runs.
#
# HADOLINT has no default. A bare `hadolint` would be a PATH lookup, which on
# the self-hosted runner can find a binary in a directory every job can write,
# instead of the one install-hadolint.sh checked for this job.
case "$kind" in
  dockerfiles) label='Dockerfile(s)/Containerfile(s)'
    : "${HADOLINT:?HADOLINT must name the hadolint binary to run}"
    found="$(find "$root" -path "$root/.git" -prune -o -path "$prune" -prune -o \
      -type f \( -iname Dockerfile -o -iname 'Dockerfile.*' \
        -o -iname '*.Dockerfile' -o -iname Containerfile \
        -o -iname 'Containerfile.*' -o -iname '*.Containerfile' \) -print0 |
      LC_ALL=C sort -z | tr '\0' '\n')" ;;
  compose|ports) label='compose file(s)'
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
