#!/usr/bin/env bash
# Must fail container-cleanup.sh: a created container keeps the image's
# anonymous volume once it is started and removed like any other.
docker create --name riftal_smoke_fixture mysql:8
