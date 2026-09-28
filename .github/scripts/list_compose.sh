#!/usr/bin/env bash
# Prints every compose file under a root, one per line.
#
# Discovery is by content, not by name. A compose file is a YAML document with
# a `services` key at column zero. Stacks live in more than one directory,
# images/ and designer/stack/ among them, and nothing requires a stack file to
# be called compose.yaml, so a name-based scan could miss one and still exit 0.
#
# One script because the workflow and the self-test must agree. Two finds drift,
# and the half that drifts is the half nothing looks at.
#
# Usage: list_compose.sh <root> [prune-path]
set -euo pipefail

root="${1:-.}"
prune="${2:-$root/.git}"

while IFS= read -r -d '' file; do
  if grep -qE '^services:([[:space:]]|$)' "$file"; then
    printf '%s\n' "$file"
  fi
done < <(
  find "$root" \
    -path "$root/.git" -prune -o \
    -path "$prune" -prune -o \
    -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 |
    LC_ALL=C sort -z
)
