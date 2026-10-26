#!/usr/bin/env bash
# Must fail container-cleanup.sh: a comment starts at its first #, so a --rm
# between two of them is still inside it.
docker run -d mysql:8 # --rm # note
