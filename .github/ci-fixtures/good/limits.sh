#!/bin/sh
# Must pass container-limits.sh: every launch carries a memory limit and --cpus
# in each form docker reads them, some behind options that take a value.
docker run --rm -m 1g --cpus 1 alpine true
docker run --memory=1g --cpus=1 --rm alpine true
docker run -v a:/b -e "A B" --name=x -m1g --cpus 1 alpine true
docker run -dm 1g --cpus 2 alpine
docker create --memory 2g --cpus 2 alpine
docker container run -m 1g --cpus 1 alpine true
"$DOCKER" run -m 1g --cpus 1 alpine true
docker run --rm \
  -m 1g \
  --cpus 1 alpine true
# A comment saying docker run alpine is not a command.
docker ps -a; docker rm -v x; docker compose config
	# container-limits: exempt only ever passed ps
	out="$(docker "$@" --filter label=x)"
