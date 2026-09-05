#!/usr/bin/env bash
# Expected findings: HOST_PUBLISH_NOT_ALLOWED, BEDROCK_TCP_PUBLISH,
# PUBLISH_ALL_NOT_ALLOWED.
set -euo pipefail

# An offline-mode downstream bound to every host interface.
docker run -d --name mine-h \
  --network riftal-stack \
  -p 0.0.0.0:19133:19132/udp \
  ghcr.io/riftal-games/riftal-core:fixture

# The proxy, published tcp. Healthy container, unjoinable server.
docker run -d --name riftal-proxy -p 19132:19132 ghcr.io/riftal-games/waterdogpe:fixture

# Everything the image exposes, straight onto the host.
docker run -d --name plots-1 -P ghcr.io/riftal-games/riftal-core:fixture
