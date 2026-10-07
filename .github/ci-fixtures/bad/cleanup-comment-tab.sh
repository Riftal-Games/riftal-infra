#!/usr/bin/env bash
# Must fail container-cleanup.sh: a comment after a tab lends its --rm no
# more than one after a space.
docker run -d mysql:8	# --rm
