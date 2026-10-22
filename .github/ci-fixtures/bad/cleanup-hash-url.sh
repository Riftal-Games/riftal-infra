#!/usr/bin/env bash
# Must fail container-cleanup.sh: the # of a URL fragment starts no comment, so
# the run after it is a command.
curl -fsS https://example.invalid/#a; docker run -d mysql:8
