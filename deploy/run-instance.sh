#!/usr/bin/env bash
# DELIBERATE BREAK, reverted in the next commit. Not a real deploy script.
#
# Written the way the house convention pushes someone to write it: the instance
# goes on the proxy's container network, so the word proxy sits on the same
# line as the -p. Before this PR's fix the whole file passed with exit 0.
set -euo pipefail

mkdir -p /opt/riftal/state

docker run -d --name mine-h \
  --network riftal-proxy-net \
  -p 0.0.0.0:19133:19132/udp \
  ghcr.io/riftal-games/riftal-core:0.0.1

docker run -d --name riftal-proxy -p19132:19132 ghcr.io/riftal-games/waterdogpe:0.0.1
