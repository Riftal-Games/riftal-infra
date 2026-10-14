#!/usr/bin/env bash
# Must fail container-cleanup.sh: the ## of ${f##*/} starts no comment, so the
# run after it is a command.
f=${f##*/}; docker run -d mysql:8
