#!/usr/bin/env bash
# Expected findings: HOST_PUBLISH_NOT_ALLOWED, BEDROCK_TCP_PUBLISH.
#
# A short flag is as capable of being missing from a table as a long one, and
# the consequence is identical: its value is read as the image, the scan of the
# command ends there, and the -p behind it is never seen. wslc's flags have
# never been enumerated, so `-k` here stands for any short flag the tables do
# not name, including the ones docker gains in its next release.
#
# One command per code, so each assertion names the command that carries it.
set -euo pipefail

# Rule 2 only: an offline-mode downstream on a host interface, published /udp.
wslc run -k 3600 --name mine-h \
  -p 0.0.0.0:19133:19132/udp \
  ghcr.io/riftal-games/riftal-core:fixture

# Rule 1 only: the proxy may publish, and this publish is unjoinable tcp.
wslc run -k 3600 --name riftal-proxy \
  -p 19132:19132 \
  ghcr.io/riftal-games/waterdogpe:fixture
