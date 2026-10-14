#!/usr/bin/env bash
# Must fail container-cleanup.sh: the string opened on the line above still
# holds the #, so it starts no comment and the run after it is a command.
msg="one
step #2"; docker run -d mysql:8
