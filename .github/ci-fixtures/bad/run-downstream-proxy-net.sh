#!/usr/bin/env bash
# Expected finding: HOST_PUBLISH_NOT_ALLOWED.
#
# The house convention puts instance ports on the proxy's container network, so
# the first real downstream run script this repo grows will name a proxy
# network on the same line as its -p. The publish is correctly /udp, so rule 1
# stays silent and only the default deny can catch it. A network name is not a
# role: mine-h is an offline-mode downstream whatever network it sits on.
set -euo pipefail

docker run -d --name mine-h \
  --network riftal-proxy-net \
  -p 0.0.0.0:19133:19132/udp \
  ghcr.io/riftal-games/riftal-core:fixture
