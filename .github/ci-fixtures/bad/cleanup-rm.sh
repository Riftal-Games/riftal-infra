#!/usr/bin/env bash
# Must fail container-cleanup.sh: the removal keeps the image's anonymous
# volume.
docker run -d --rm --name riftal_smoke_fixture mysql:8
docker rm -f riftal_smoke_fixture
