#!/usr/bin/env bash
# Expected finding: HOST_PUBLISH_NOT_ALLOWED.
#
# There is no --name here, so the image is the only identity the command
# offers, and the word after an unsized flag is either that flag's value or the
# image with no way to tell. The pidfile path says proxy, and reading a tier
# out of it would hand an offline-mode downstream the proxy's right to bind a
# host interface. The publish is correctly /udp, so rule 1 stays silent and
# only the default deny can catch it.
set -euo pipefail

podman run -d --conmon-pidfile /run/riftal-proxy.pid \
  -p 0.0.0.0:19133:19132/udp \
  ghcr.io/riftal-games/riftal-core:fixture
