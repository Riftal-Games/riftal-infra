#!/usr/bin/env bash
# Must fail container-cleanup.sh: docker named through a quoted variable is
# still docker.
"$DOCKER" run mysql:8 true
