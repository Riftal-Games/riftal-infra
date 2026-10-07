#!/bin/sh
# Must fail container-limits.sh at each container-limits line: none is
# exempt <reason>.
# container-limits: exempt
docker run -m 1g --cpus 1 alpine
# container-limits: keep a service
docker run -m 1g --cpus 1 alpine
