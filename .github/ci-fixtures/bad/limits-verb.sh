#!/bin/sh
# Must fail container-limits.sh at every command: its verb is a variable, so
# it may be a launch the check cannot read.
docker "$@"
docker $verb alpine
docker container "${verb}" alpine
