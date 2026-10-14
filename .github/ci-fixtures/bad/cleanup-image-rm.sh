#!/usr/bin/env bash
# Must fail container-cleanup.sh: an image named rm does not make a run a
# removal.
docker run -d rm
