#!/usr/bin/env bash
# Must fail container-cleanup.sh: each --rm follows its image, so docker hands
# it to the container and starts the container without it.
docker run -d mysql:8 true --rm
docker run -d mysql:8 --rm
docker run --init mysql:8 --rm
docker run -it mysql:8 --rm
docker run -eA=b mysql:8 --rm
docker run --name=riftal_smoke_fixture mysql:8 --rm
"$DOCKER" container create mysql:8 --rm
docker run -d mysql:8 \
  --rm
