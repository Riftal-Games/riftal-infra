#!/usr/bin/env bash
# GO-LIVE.md step 1. Requires CORE_IMAGE, the instance's image tag;
# CUSTODY_CONFIG, the RiftalCustody config.yml it boots with; INSTANCE_VOLUME,
# its data volume, read for its driver and never mounted. WRITES per kind
# defaults to 1000. Exits as write-latency-check.sh, or 2 when it cannot run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER=docker
WRITES="${WRITES:-1000}"

refuse() {
  printf 'WRITE LATENCY REFUSED: %s\n' "$1" >&2
  exit 2
}

for name in CORE_IMAGE CUSTODY_CONFIG INSTANCE_VOLUME; do
  [ -n "${!name:-}" ] || refuse "$name is not set"
done
bash "$SCRIPT_DIR/write-latency-check.sh" "$CUSTODY_CONFIG" --bounds

driver="$("$DOCKER" volume inspect -f '{{.Driver}}' "$INSTANCE_VOLUME")" \
  || refuse "cannot inspect volume $INSTANCE_VOLUME"
# A volume's options can name the instance's own storage, a local bind's
# device for one, so a copy of them would probe, and write into, that storage.
[ "$("$DOCKER" volume inspect -f '{{len .Options}}' "$INSTANCE_VOLUME")" = 0 ] \
  || refuse "$INSTANCE_VOLUME carries driver options; probe a volume made the same way by hand instead"

volume="riftal_smoke_latency_$$_$(date +%s)"
"$DOCKER" volume create --driver "$driver" "$volume" >/dev/null
timings="$(mktemp)"
trap 'rm -f "$timings"; "$DOCKER" volume rm "$volume" >/dev/null' EXIT
printf 'WRITE LATENCY: %s writes of each kind on a %s volume, image %s\n' "$WRITES" "$driver" "$CORE_IMAGE"

# The instance's own memory and CPU limits, images/compose.yaml.
"$DOCKER" run --rm --network none -m 2g --cpus 2 --entrypoint php \
  -v "$volume:/data" -v "$SCRIPT_DIR/write-latency-probe.php:/probe.php:ro" \
  "$CORE_IMAGE" /probe.php /data "$WRITES" >"$timings" \
  || refuse "the probe container failed; its error is above"
bash "$SCRIPT_DIR/write-latency-check.sh" "$CUSTODY_CONFIG" <"$timings"
