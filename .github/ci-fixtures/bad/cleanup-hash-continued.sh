#!/usr/bin/env bash
# Must fail container-cleanup.sh: the string runs across the continuation and
# still holds the #, so it starts no comment and the run after it is a command.
echo "a \
b #c"; docker run -d mysql:8
