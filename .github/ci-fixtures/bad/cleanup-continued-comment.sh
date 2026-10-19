#!/usr/bin/env bash
# Must fail container-cleanup.sh: the comment line ends the continued run, so
# its --rm is not the run's and mysql:8 is a command of its own.
docker run -d \
# --rm
  mysql:8
