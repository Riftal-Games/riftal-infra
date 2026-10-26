#!/usr/bin/env bash
# Must fail container-cleanup.sh: the -v belongs to the echo after the `||`,
# not to the removal.
docker rm -f riftal_smoke_fixture || echo -v
