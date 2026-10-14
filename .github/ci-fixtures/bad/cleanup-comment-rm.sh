#!/usr/bin/env bash
# Must fail container-cleanup.sh: the -v is in a trailing comment, so the
# removal takes no volumes.
docker rm riftal_smoke_fixture # -v
