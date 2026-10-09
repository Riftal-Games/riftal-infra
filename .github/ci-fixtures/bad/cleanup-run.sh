#!/usr/bin/env bash
# Must fail container-cleanup.sh: the first run has no --rm, and the --rm of
# the run after it on the same line is not its own.
docker run -d --name riftal_smoke_fixture \
  mysql:8; docker run --rm mysql:8 true
docker rm -f -v riftal_smoke_fixture
