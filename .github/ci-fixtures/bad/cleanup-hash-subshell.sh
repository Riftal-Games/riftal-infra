#!/usr/bin/env bash
# Must fail container-cleanup.sh: the # sits in a string nested inside a
# quoted $(...), so it starts no comment and the run after it is a command.
x="$(echo " #")"; docker run -d mysql:8
