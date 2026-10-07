#!/usr/bin/env bash
# Must fail container-cleanup.sh: an indented opt-out keeps the first command on
# its line, so a removal there leaves it unused and the run after goes unkept.
          # container-cleanup: keep a service
          docker rm -v old; docker run -d --restart always mysql:8
