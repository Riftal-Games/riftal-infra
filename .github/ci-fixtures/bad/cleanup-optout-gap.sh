#!/usr/bin/env bash
# Must fail container-cleanup.sh: another comment separates the opt-out from
# the run, so the opt-out is not directly above any container.
# container-cleanup: keep a long-lived service
# the service outlives this script
docker run -d --restart unless-stopped --name riftal_smoke_fixture mysql:8
docker rm -f -v riftal_smoke_fixture
