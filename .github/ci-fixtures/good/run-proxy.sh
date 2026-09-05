#!/usr/bin/env bash
# Expected: clean. The proxy is the sole public entry point, and it says so in
# its own name, which is what lets the checker allow the publish.
set -euo pipefail

docker run -d --name riftal-proxy \
  --network riftal-stack \
  -p 19132:19132/udp \
  ghcr.io/riftal-games/waterdogpe:fixture

# The database is published for local inspection only.
docker run -d --name riftal-mysql \
  --network riftal-stack \
  -p 127.0.0.1:3306:3306 \
  mysql:8
