#!/bin/sh
# Must fail container-limits.sh at the second launch only: an exemption
# excuses the first report under it and nothing else.
# container-limits: exempt the first launch only
docker run --cpus 1 alpine; docker run -m 1g alpine
