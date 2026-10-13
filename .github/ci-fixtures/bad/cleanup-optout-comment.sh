#!/usr/bin/env bash
# Must fail container-cleanup.sh: a comment between the opt-out and the run
# means the opt-out is not directly above it.
# container-cleanup: keep a service
# the service
docker run -d mysql:8
