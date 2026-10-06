#!/usr/bin/env bash
# Must fail container-cleanup.sh: the opt-out sits above a run that already
# has --rm, so it keeps nothing and would silently cover a later edit.
# container-cleanup: keep a long-lived service
docker run -d --rm --name riftal_smoke_fixture mysql:8
docker rm -f -v riftal_smoke_fixture
