#!/usr/bin/env bash
# Must fail container-cleanup.sh: the opt-out is the last line of the file,
# so there is no container under it to keep.
docker run --rm --name riftal_smoke_fixture mysql:8 true
# container-cleanup: keep a long-lived service
