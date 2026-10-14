#!/usr/bin/env bash
# Must fail container-cleanup.sh: the run without --rm ends the file on a
# continuation, so no line after it closes the command.
docker run -d mysql:8 \
