# Must fail container-limits.sh at every launch: each lacks -m/--memory, --cpus or both before its image.
docker run --rm --cpus 1 alpine true
docker run --rm -m 1g alpine true
docker run --rm alpine true
docker create --cpus 1 alpine
docker run --memory-swap 1g --cpus 1 alpine
docker run --cpu-shares 512 -m 1g --cpus 1 alpine
docker run --rm \
  -m 1g --cpus 1 alpine
docker run --name=x alpine -m 1g --cpus 1
docker run -e "X -m 1g --cpus 1" alpine
docker run -e 'X -m 1g --cpus 1' alpine
docker run --cpus 1 -m
docker run "$@" -m 1g --cpus 1 alpine
