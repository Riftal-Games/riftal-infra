#!/usr/bin/env bash
# Must fail container-cleanup.sh: an escaped quote outside a string opens none,
# so the # after the run starts a comment and its --rm is not the run's.
echo \"; docker run -d mysql:8 # " --rm
