#!/usr/bin/env bash
# Must fail container-cleanup.sh: an ordinary command between the opt-out and
# the run means the opt-out is not directly above it.
# container-cleanup: keep a service
echo starting
docker run -d mysql:8
