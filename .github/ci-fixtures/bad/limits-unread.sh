# Must fail container-limits.sh at every line after this one: none is a plain limited launch or an allowlisted command.
true&&docker run --rm alpine
true;docker run --rm alpine
a|docker run --rm alpine
a&docker run --rm alpine
docker run -m 1g --cpus 1 alpine;docker run --rm alpine
$(command -v docker) run --rm alpine
"$(command -v docker)" run --rm alpine
docker --context default run --rm alpine
docker -H unix:///var/run/docker.sock run --rm alpine
docker --debug run --rm alpine
docker -l debug run --rm alpine
${DOCKER:-docker} run --rm alpine
d=docker; $d run --rm alpine
d=docker
"$DOCKER_BIN" run --rm alpine
docker "run" --rm alpine
docker 'create' alpine
docker `echo run` --rm alpine
\docker run --rm alpine
DOCKER run -m 1g --cpus 1 alpine
/usr/bin/docker run -m 1g --cpus 1 alpine
docker-compose up -d
docker compose -f x run app
docker container run -m 1g --cpus 1 alpine
docker $verb alpine
docker "$@"
docker
docker run -m 1g --cpus 1 alpine && true
docker run -m 1g --cpus 1 $(echo alpine)
docker run -m 1g --cpus 1 alpine # a trailing comment
x="$(docker run -m 1g --cpus 1 alpine)"
sh -c 'docker run --rm alpine'
x=`docker ps`
docker ps || docker run --rm alpine
docker ps | $d run --rm alpine
docker ps >/tmp/out
# `docker run --rm alpine` inside a comment
# $(docker run --rm alpine)
uses: docker://alpine
# " docker run --rm alpine
# ' docker run --rm alpine
