#!/usr/bin/env bash
# Expected findings: HOST_PUBLISH_NOT_ALLOWED, BEDROCK_TCP_PUBLISH.
#
# Neither --memory-reservation nor --cpu-shares is in the parser's flag tables,
# so an unlisted long flag ahead of a -p is the shape a real deploy script
# grows into. If the parser guesses arity it reads `1g` as the image, stops,
# and prints 0 findings on a downstream that is wide open to the host.
#
# One command per code, so each assertion names the command that carries it.
# Pair this with good/ops.sh, which must stay silent on `mkdir -p`: the two
# together are the whole of the fail-closed tradeoff.
set -euo pipefail

# Rule 2 only: an offline-mode downstream on a host interface, published /udp.
docker run -d --memory-reservation 1g --name mine-h \
  -p 0.0.0.0:19133:19132/udp \
  ghcr.io/riftal-games/riftal-core:fixture

# Rule 1 only: the proxy may publish, and this publish is unjoinable tcp.
docker run -d --cpu-shares 512 --name riftal-proxy \
  -p 19132:19132 \
  ghcr.io/riftal-games/waterdogpe:fixture
