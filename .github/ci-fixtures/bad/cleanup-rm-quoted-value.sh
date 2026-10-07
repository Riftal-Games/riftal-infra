#!/usr/bin/env bash
# Must fail container-cleanup.sh: each --rm is inside the quoted value of an
# option, so docker reads it as part of that value and starts no --rm.
docker run -e "X --rm Y" mysql:8 true
docker run --health-cmd 'x --rm y' mysql:8
docker run --env="X --rm Y" mysql:8 true
docker run -e'X --rm Y' mysql:8 true
docker run -e "X \" --rm Y" mysql:8 true
docker run -e $'X \' --rm Y' mysql:8 true
