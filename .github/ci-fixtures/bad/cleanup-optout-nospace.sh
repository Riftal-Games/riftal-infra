#!/usr/bin/env bash
# Must fail container-cleanup.sh: one space separates the colon from keep, so
# an opt-out reads as it is written everywhere else.
# container-cleanup:keep it running
docker run --rm mysql:8 true
