#!/usr/bin/env bash
# Must fail container-cleanup.sh: docker reads the last --rm before the image,
# and each of these leaves it false, is refused by docker, or quotes its value,
# which the scanner does not read and so never takes for true.
docker run --rm --rm=false mysql:8 true
docker run --rm=false mysql:8 true
docker run --rm=0 mysql:8 true
docker run --rm -d --rm=f mysql:8 true
docker run --rm=yes mysql:8 true
docker run --rm="true" mysql:8 true
