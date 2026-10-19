#!/usr/bin/env bash
# Must fail container-cleanup.sh: a comment lends its --rm to no run, whichever
# spelling names docker.
"$DOCKER" run -d mysql:8 #comment --rm
