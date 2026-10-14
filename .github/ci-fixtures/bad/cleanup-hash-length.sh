#!/usr/bin/env bash
# Must fail container-cleanup.sh: the # of ${#a} starts no comment, so the run
# after it is a command.
x=${#a}; docker run -d mysql:8
