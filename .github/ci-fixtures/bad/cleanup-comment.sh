#!/usr/bin/env bash
# Must fail container-cleanup.sh: the --rm is in a trailing comment, which the
# shell never passes to docker.
docker run mysql:8 true # --rm
