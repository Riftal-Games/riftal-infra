# Must fail container-limits.sh at every launch: each lacks -m, --cpus or both where docker reads them.
docker run --rm --cpus 1 alpine true
docker run --rm -m 1g alpine true
docker run --rm alpine true
docker create --cpus 1 alpine
docker container create --cpus 1 alpine
docker container run --cpus 1 alpine
$DOCKER run --cpus 1 alpine
docker run --memory-swap 1g --cpus 1 alpine
docker run --cpu-shares 512 -m 1g alpine
docker run --rm \
  --cpus 1 alpine
docker run
docker run --name=x alpine -m 1g --cpus 1
docker run -e "X \" -m 1g --cpus 1" alpine
docker run -e $'X \' -m 1g --cpus 1' alpine
docker run -e X\ -m\ 1g\ --cpus\ 1 alpine
docker run --cpus 1 -e "$(echo "a -m 1g")" alpine
docker --context default run --rm alpine
docker -H unix:///var/run/docker.sock run --rm alpine
docker --debug run --rm alpine
docker -l debug container run --rm alpine
docker --config x --log-level=info create alpine
${DOCKER:-docker} run --rm alpine
"${DOCKER:-docker}" run --rm alpine
d=docker; $d run --rm alpine
"$DOCKER_BIN" run --rm alpine
\docker run --rm alpine
docker "run" --rm alpine
docker 'create' alpine
sh -c 'docker run --rm alpine'
x=`docker run --rm alpine`
