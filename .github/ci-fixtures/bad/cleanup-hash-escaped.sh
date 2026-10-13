#!/usr/bin/env bash
# Must fail container-cleanup.sh: an escaped quote does not close the string,
# so the # is still quoted and the run after it is a command.
echo "a\"b #c"; docker run -d mysql:8
