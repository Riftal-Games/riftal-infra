#!/usr/bin/env bash
# Runs resolve_states.php in the pinned core image (images/core-image.sha) over
# a census and prints the core's verdict on every state in it.
#
#   resolve.sh run [census.json]    print the verdict
#   resolve.sh check [census.json]  fail unless the verdict is the one committed in the census
#   resolve.sh write [census.json]  record the verdict in the census
#
# The container has no network, no published port and a read-only view of the
# census and the script. It starts nothing a client could reach.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
. "$REPO/images/core-image.sh"
core_image || { printf 'the census was never resolved\n'; exit 1; }

mode="${1:-}"
census="${2:-$DIR/rift_prison/census.json}"
case "$mode" in
  run|check|write) ;;
  *) printf 'usage: resolve.sh run [census.json] | check | write\n' >&2; exit 2 ;;
esac

verdict() {
  docker run --rm -m 1g --cpus 1 --network none \
    -v "$DIR/resolve_states.php:/resolve_states.php:ro" \
    -v "$(dirname "$census"):/census:ro" \
    --entrypoint php "$CORE_IMAGE" /resolve_states.php "/census/$(basename "$census")" "${CORE_IMAGE#*:}"
}

if [ "$mode" = run ]; then
  verdict
else
  verdict | uv run --frozen --project "$REPO/designer" python -I -m designer.pit_census resolution "$mode" --census "$census"
fi
