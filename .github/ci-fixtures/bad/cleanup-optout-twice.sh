#!/usr/bin/env bash
# Must fail container-cleanup.sh: the first of two opt-outs in a row has the
# second, not a container, directly under it.
# container-cleanup: keep a service
# container-cleanup: keep a service
docker run -d mysql:8
