#!/usr/bin/env bash
# Expected: clean. Ordinary shell that is not a container publish.
#
# mkdir -p and grep -P are not port flags. A gate that reddens on them gets
# weakened or excluded by whoever hits it first, and the control dies by
# attrition rather than by anyone deciding to remove it. deploy/ is empty today
# only because nothing has landed there yet.
set -euo pipefail

mkdir -p /opt/riftal/state
grep -P '^[0-9]+$' /opt/riftal/state/ids.txt || true
cp -p /opt/riftal/state/ids.txt /opt/riftal/state/ids.bak

# A container that publishes nothing. Its network is named for the proxy, which
# buys it no permission, and the mkdir before it is not part of the run.
mkdir -p /srv/worlds && docker run -d --name mine-h \
  --network riftal-proxy-net \
  ghcr.io/riftal-games/riftal-core:fixture

# The -p here belongs to the container's own command, after the image, not to
# docker.
docker run --detach ghcr.io/riftal-games/riftal-core:fixture sh -c "mkdir -p /data/tmp"

# The same thing unquoted. This one only stays clean while --rm is a flag the
# parser can size: an unsized flag makes the image boundary untrustworthy and
# the scan runs on past it, which is what bad/run-unlisted-flag.sh requires.
# Drop --rm from LONG_BOOLEAN_FLAGS and this line reports a publish of /data.
docker run --rm ghcr.io/riftal-games/riftal-core:fixture sh -c mkdir -p /data/tmp
