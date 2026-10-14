#!/usr/bin/env bash
# Must fail container-cleanup.sh: a removal that ends its line still takes no
# volumes.
docker ps -aq | xargs docker rm
