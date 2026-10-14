#!/usr/bin/env bash
# Must fail container-cleanup.sh: the continuation joins foo and #; into one
# word, so the line under it is no comment and its run is a command.
echo foo\
#; docker run -d mysql:8
