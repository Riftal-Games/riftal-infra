#!/usr/bin/env bash
# Must fail container-cleanup.sh: an escaped blank joins the # to the word
# before it, so it starts no comment and the run after it is a command.
echo \ #b; docker run -d mysql:8
