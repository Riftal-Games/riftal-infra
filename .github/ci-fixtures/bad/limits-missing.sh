#!/bin/sh
# Must fail container-limits.sh at every launch: each lacks a memory limit,
# --cpus or both, under each spelling of a launch docker accepts.
docker run --rm --cpus 1 alpine true
docker run --rm -m 1g alpine true
docker run --rm alpine true
docker create --cpus 1 alpine
docker container create --cpus 1 alpine
docker container run --cpus 1 alpine
$DOCKER run --cpus 1 alpine
${DOCKER} run --cpus 1 alpine
"$DOCKER" run --cpus 1 alpine
"${DOCKER}" run --cpus 1 alpine
docker run --memory-swap 1g --cpus 1 alpine
docker run --cpu-shares 512 -m 1g alpine
docker run --rm \
  --cpus 1 alpine
docker run
