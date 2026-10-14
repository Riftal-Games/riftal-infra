#!/usr/bin/env bash
# Must fail container-cleanup.sh: an opt-out is a whole line, so one that
# follows other text in a comment keeps nothing.
# a service # container-cleanup: keep a service
docker run -d mysql:8
