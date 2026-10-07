#!/usr/bin/env bash
# Must fail container-cleanup.sh: an opt-out starts with keep, it does not
# merely contain it.
# container-cleanup: why keep it
docker run --rm mysql:8 true
