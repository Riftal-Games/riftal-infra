#!/usr/bin/env bash
# Must fail container-cleanup.sh: keep is a word of its own, so keepalive is
# no opt-out.
# container-cleanup: keepalive
docker run --rm mysql:8 true
