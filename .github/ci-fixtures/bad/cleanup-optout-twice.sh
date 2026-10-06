#!/usr/bin/env bash
# Must fail container-cleanup.sh: two opt-outs are stacked over one run, so
# the first keeps nothing.
# container-cleanup: keep a long-lived service
# container-cleanup: keep the same service again
docker run -d --restart unless-stopped --name riftal_smoke_fixture mysql:8
docker rm -f -v riftal_smoke_fixture
