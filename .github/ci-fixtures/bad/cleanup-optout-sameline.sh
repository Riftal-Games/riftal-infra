#!/usr/bin/env bash
# Must fail container-cleanup.sh: the first command under the opt-out is an
# echo, so the run after it on the same line is not kept.
# container-cleanup: keep a service
echo starting; docker run -d mysql:8
