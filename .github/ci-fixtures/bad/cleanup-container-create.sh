#!/usr/bin/env bash
# Must fail container-cleanup.sh: the long form of create is held to the same
# rule as the short one.
docker container create --name riftal_smoke_fixture mysql:8
