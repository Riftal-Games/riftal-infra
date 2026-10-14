#!/usr/bin/env bash
# Must fail container-cleanup.sh: a backslash inside a comment continues
# nothing, so the --rm under it is a command of its own.
docker run -d mysql:8 # \
  --rm
