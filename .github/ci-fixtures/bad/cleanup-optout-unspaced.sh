#!/usr/bin/env bash
# Must fail container-cleanup.sh: an opt-out starts with `# container-cleanup:`
# exactly, so this comment keeps nothing.
#container-cleanup: keep a service
docker run -d mysql:8
