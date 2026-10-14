#!/usr/bin/env bash
# Must fail container-cleanup.sh: an apostrophe inside double quotes opens no
# quote, and the # beside it is quoted, so the run after it is a command.
echo "it's #1"; docker run -d mysql:8
