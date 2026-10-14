#!/usr/bin/env bash
# Must fail container-cleanup.sh: the --rm belongs to the tee after the `|`,
# not to the run.
docker run mysql:8 true | tee --rm
