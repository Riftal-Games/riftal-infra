#!/bin/sh
# Must fail container-limits.sh at every launch: its limits sit inside the
# value of -e, quoted or escaped, so they are no flags.
docker run -e "X -m 1g --cpus 1" alpine
docker run -e 'X -m 1g --cpus 1' alpine
docker run -e "X \" -m 1g --cpus 1" alpine
docker run -e $'X \' -m 1g --cpus 1' alpine
docker run -e X\ -m\ 1g\ --cpus\ 1 alpine
docker run -e $'X -m 1g --cpus 1' alpine
