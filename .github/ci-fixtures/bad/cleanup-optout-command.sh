#!/usr/bin/env bash
# Must fail container-cleanup.sh: an ordinary command sits between the opt-out
# and the run, so the opt-out is not directly above any container.
# container-cleanup: keep a long-lived service
echo starting
docker run -d --name riftal_smoke_fixture mysql:8
docker rm -f -v riftal_smoke_fixture
