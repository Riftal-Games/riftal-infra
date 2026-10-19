#!/usr/bin/env bash
# Must fail container-cleanup.sh: a # line in a here-document body is text,
# and the run after the body is a command.
cat <<EOF
#
EOF
docker run -d mysql:8
