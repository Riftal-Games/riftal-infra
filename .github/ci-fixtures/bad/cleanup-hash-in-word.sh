#!/usr/bin/env bash
# Must fail container-cleanup.sh: each --rm is text in the container's own
# command, not a flag of the run, and a # inside a word beside it does not
# make it one.
docker run -d mysql:8 sh -c 'echo step#1 --rm now'
docker run -d mysql:8 sh -c 'echo --rm#'
docker run -d mysql:8 sh -c 'echo --rm1#'
