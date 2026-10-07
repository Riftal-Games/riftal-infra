#!/bin/sh
# Must fail container-limits.sh at every launch: its limits follow the image,
# where docker hands them to the container.
docker run --rm alpine -m 1g --cpus 1
docker run --name=x alpine -m 1g --cpus 1
docker run -it alpine -m 1g --cpus 1
