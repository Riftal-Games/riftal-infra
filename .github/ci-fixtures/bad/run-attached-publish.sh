#!/usr/bin/env bash
# Expected findings: BEDROCK_TCP_PUBLISH, HOST_PUBLISH_NOT_ALLOWED.
#
# Docker accepts a short flag with its value attached, so -p19132:19132 is a
# tcp publish of the Bedrock port written in a form that a match requiring a
# separator never sees. The --publish=... long form is the same hole on a
# downstream that has no business on a host interface at all.
set -euo pipefail

docker run -d --name riftal-proxy -p19132:19132 ghcr.io/riftal-games/waterdogpe:fixture

docker run -d --name plots-1 --publish=0.0.0.0:19134:19132/udp ghcr.io/riftal-games/riftal-core:fixture
