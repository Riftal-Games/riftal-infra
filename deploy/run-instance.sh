#!/usr/bin/env bash
# Deliberate break on a real repo path, not a fixture. Both commands are the
# reviewer's and QA's own repros, written the way the house convention pushes
# someone to write them.
set -euo pipefail

docker run -d -c 512 --name mine-h \
  -p 0.0.0.0:19133:19132/udp \
  ghcr.io/riftal-games/riftal-core:0.0.1

podman run -d --conmon-pidfile /run/riftal-proxy.pid \
  -p 0.0.0.0:19133:19132/udp \
  ghcr.io/riftal-games/riftal-core:0.0.1
