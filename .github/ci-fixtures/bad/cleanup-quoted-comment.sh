#!/usr/bin/env bash
# Must fail container-cleanup.sh: a # inside quotes starts no comment, so the
# run after the echo is a command.
echo "step #1"; docker run -d mysql:8
