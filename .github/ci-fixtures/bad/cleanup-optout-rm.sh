#!/usr/bin/env bash
# Must fail container-cleanup.sh: an opt-out excuses a missing --rm, never a
# removal without -v.
# container-cleanup: keep a service
docker rm -f riftal_smoke_fixture
