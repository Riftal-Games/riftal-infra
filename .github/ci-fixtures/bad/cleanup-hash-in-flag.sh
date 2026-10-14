#!/usr/bin/env bash
# Must fail container-cleanup.sh: a quoted # in an option lends the run no
# --rm.
docker run -d -e "A=#" mysql:8
