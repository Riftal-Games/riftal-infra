#!/usr/bin/env bash
# Expected: clean. The proxy is the sole public entry point, and it says so in
# its own name, which is what lets the checker allow the publish.
set -euo pipefail

docker run -d --name riftal-proxy \
  --network riftal-stack \
  -p 19132:19132/udp \
  ghcr.io/riftal-games/waterdogpe:fixture

# No --name, so the image is what says this is the proxy, and -c has to be
# sized correctly for the image to be the word the parser lands on. Drop c from
# SHORT_VALUE_FLAGS and 512 becomes the candidate image, which grants nothing,
# and this allowed publish turns red.
docker run -d -c 512 \
  -p 19132:19132/udp \
  ghcr.io/riftal-games/waterdogpe:fixture

# The database is published for local inspection only.
docker run -d --name riftal-mysql \
  --network riftal-stack \
  -p 127.0.0.1:3306:3306 \
  mysql:8
