#!/usr/bin/env bash
# Must fail container-cleanup.sh: $'a\'b' is one closed word, so the --rm after
# it is in a comment and the run has none.
docker run -d mysql:8 $'a\'b' # --rm
