#!/usr/bin/env bash
# Must fail container-cleanup.sh: every docker named through a variable on a
# line is docker, not only the first.
$DOCKER rm -v a; $DOCKER run mysql:8 true
