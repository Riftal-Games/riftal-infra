#!/usr/bin/env bash
# CI only (ADR 027). Builds the ops image the way release-image.sh builds it,
# from this checkout, with fixture migrations and grants and none of the core
# image or levels a full release needs. Then runs the dump, restore and
# migration self-tests with OPS_IMAGE set, so each of those scripts runs from
# the image's own /opt/riftal/ops tree and meets the image's Ubuntu client and
# tools, not mysql:8's or the dev image's. Builds under riftal_smoke_ names and
# removes them. The self-tests never start the image's own command, which is
# the backup loop.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/release-image.sh"

SUFFIX="$$-$(date +%s)"
BREF="riftal_smoke_ops_selftest/backup:$SUFFIX"
BASE="riftal_smoke_ops_selftest/backup-base:$SUFFIX"
WORK="$(mktemp -d)"

cleanup() {
  docker image rm "$BREF" "$BASE" >/dev/null 2>&1 || true
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir "$WORK/ctx" "$WORK/migrations"
printf 'CREATE TABLE smoke_a (id INT);\n' >"$WORK/migrations/0001_a.sql"
printf 'REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines;\n' >"$WORK/grants.sql"

build_ops_image "$BREF" "$BASE" "$WORK/ctx" "$WORK/migrations" "$WORK/grants.sql" \
  "$(git -C "$DIR/.." rev-parse --verify HEAD)" 0123456789abcdef0123456789abcdef01234567

# The tree the self-tests run from is whole, and the image is the one just built.
docker run --rm -m 1g --cpus 1 --network none --entrypoint sh "$BREF" \
  -c 'cd /opt/riftal && sha256sum -c --quiet ops.sha256'
printf 'ops image %s (%s)\n' "$BREF" "$BID"

for test in deploy/selftest.sh deploy/restore-selftest.sh migrations/selftest.sh; do
  printf '\n== %s, run from the ops image\n' "$test"
  OPS_IMAGE="$BREF" bash "$DIR/../$test"
done
