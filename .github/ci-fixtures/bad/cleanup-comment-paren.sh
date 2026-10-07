#!/usr/bin/env bash
# Must fail container-cleanup.sh: a # straight after ) still opens a comment,
# so the --rm behind it is not the run's.
(docker run -d mysql:8)# --rm
