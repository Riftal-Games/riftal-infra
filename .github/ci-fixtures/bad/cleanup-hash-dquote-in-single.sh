#!/usr/bin/env bash
# Must fail container-cleanup.sh: double quotes inside single quotes open
# nothing, and the # between them is quoted, so the run after it is a command.
echo 'say "#"'; docker run -d mysql:8
