#!/usr/bin/env bash
# Must fail container-cleanup.sh: a run named in a trailing comment lends the
# real run before it none of its flags.
docker run -d mysql:8 # docker run --rm mysql:8
