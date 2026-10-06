#!/usr/bin/env bash
# Must fail container-cleanup.sh: the opt-out gives no reason, so it keeps
# nothing.
# container-cleanup: keep
docker run -d --restart unless-stopped --name riftal_smoke_fixture mysql:8
docker rm -f -v riftal_smoke_fixture
