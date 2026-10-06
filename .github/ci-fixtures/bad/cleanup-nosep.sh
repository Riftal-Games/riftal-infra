#!/usr/bin/env bash
# Must fail container-cleanup.sh: the first run has no --rm, and with no
# separator before the second run, only the next `docker` ends the first.
docker run -d --name riftal_smoke_fixture mysql:8 docker run --rm mysql:8 true
docker rm -f -v riftal_smoke_fixture
