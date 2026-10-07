#!/bin/sh
# Must fail container-limits.sh at each exemption: none has a report directly
# under it to excuse.
# container-limits: exempt over a launch that needs none
docker run -m 1g --cpus 1 alpine
# container-limits: exempt over a blank line

# container-limits: exempt over a comment
# a comment
docker run -m 1g --cpus 1 alpine
# container-limits: exempt at the end of the file
