#!/usr/bin/env bash
# Must fail container-cleanup.sh: the opt-out keeps the first run on its line,
# never the second.
# container-cleanup: keep a service
docker run -d mysql:8; docker run -d mysql:8
