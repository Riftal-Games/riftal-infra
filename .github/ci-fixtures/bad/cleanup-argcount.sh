#!/usr/bin/env bash
# Must fail container-cleanup.sh: the # of $# follows no blank, so it starts no
# comment and the run after it is a command.
[ $# -eq 0 ] || docker run -d mysql:8
