#!/usr/bin/env bash
# Must fail container-cleanup.sh: the --rm is in a trailing comment, so the
# run has none.
docker run -d mysql:8 # --rm
