#!/usr/bin/env bash
# Must fail container-cleanup.sh: the --rm belongs to the echo after the `&`,
# not to the run.
docker run -d mysql:8 & echo --rm
