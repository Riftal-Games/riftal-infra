#!/usr/bin/env bash
# Fails when the core image's start-pocketmine (pmmp-core docker/start.sh) is
# not the version start-instance.sh was last checked against, recorded in
# start-sh.sha256 (riftal-infra#272). start-instance.sh copies that script's
# behaviour by hand, so a change to it has to be carried across by hand too,
# and this is what says one happened.
#
# Reads the script out of the core image pinned in ../../core-image.sha, which
# is already on this machine, and never pulls: a registry copy is not what the
# instances here run. START_SH_IMAGE names another image for the self-test. A
# missing image fails, because a check that skips is a check nobody ran.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../core-image.sh"
RECORD="${START_SH_RECORD:-$DIR/start-sh.sha256}"
IN_IMAGE=/usr/bin/start-pocketmine

field() { sed -n "s/^$1 \([0-9a-f]\{$2\}\)\$/\1/p" "$RECORD"; }
recorded="$(field sha256 64)"
commit="$(field pmmp-core 40)"
if [ -z "$recorded" ] || [ -z "$commit" ]; then
  printf '::error::%s needs a "sha256 <64 hex>" line and a "pmmp-core <40 hex>" line\n' "$RECORD"
  exit 1
fi

if [ -n "${START_SH_IMAGE:-}" ]; then
  IMAGE="$START_SH_IMAGE"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf '::error::image %s is not present, so start-instance.sh was never checked against core'"'"'s start.sh. This check never pulls.\n' "$IMAGE"
    exit 1
  fi
else
  core_image || { printf 'start-instance.sh was never checked against core'"'"'s start.sh\n'; exit 1; }
  IMAGE="$CORE_IMAGE"
fi

if ! out="$(docker run --rm --pull never --network none -m 1g --cpus 1 \
    --entrypoint sha256sum "$IMAGE" "$IN_IMAGE" 2>&1)"; then
  printf '::error::could not hash %s in %s: %s\n' "$IN_IMAGE" "$IMAGE" "$out"
  exit 1
fi
actual="${out%% *}"

if [ "$actual" != "$recorded" ]; then
  printf '::error::%s in %s has sha256 %s, but %s records %s (pmmp-core %s). Re-check start-instance.sh against the new pmmp-core docker/start.sh, carry any change across, then record the new hash and the pmmp-core commit it came from.\n' \
    "$IN_IMAGE" "$IMAGE" "$actual" "$RECORD" "$recorded" "$commit"
  exit 1
fi
printf 'start.sh in %s matches the recorded %s (pmmp-core %s)\n' "$IMAGE" "$recorded" "$commit"
