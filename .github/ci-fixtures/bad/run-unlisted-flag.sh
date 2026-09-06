#!/usr/bin/env bash
# Expected findings: HOST_PUBLISH_NOT_ALLOWED, BEDROCK_TCP_PUBLISH.
#
# Neither --memory-reservation nor --cpu-shares is in the parser's flag tables,
# and nobody has enumerated wslc's flags at all, so an unlisted flag ahead of a
# -p is the shape a real deploy script grows into. Both publishes here sit
# after one. If the parser ever guesses arity again it will read `1g` as the
# image, stop, and print 0 findings on a downstream that is wide open to the
# host. Pair this with good/ops.sh: that one must stay silent on `mkdir -p`,
# and the two together are the whole of the fail-closed tradeoff.
set -euo pipefail

docker run -d --memory-reservation 1g --name mine-h \
  -p 0.0.0.0:19133:19132/udp \
  ghcr.io/riftal-games/riftal-core:fixture

docker run -d --cpu-shares 512 --name plots-1 \
  -p 19132:19132 \
  ghcr.io/riftal-games/riftal-core:fixture
