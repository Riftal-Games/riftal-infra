# Must pass container-limits.sh: each launch carries both limits, each other docker command is read.
docker run --rm -m 1g --cpus 1 alpine true
docker run --memory=1g --cpus=1 --rm alpine true
docker run -v a:/b -e "A B" --name=x -m1g --cpus 1 alpine true
docker run -dm 1g --cpus 2 alpine
docker create --memory 2g --cpus 2 alpine
docker --context default -D -H unix:///x --log-level=info container run -m 1g --cpus 1 alpine
${DOCKER:-docker} "run" -m 1g --cpus 1 alpine
"$d" container 'create' -m 1g --cpus 1 alpine
out="$(docker run -m 1g --cpus 1 alpine "$(echo "-a")")"
sh -c 'docker run -m 1g --cpus 1 alpine'
docker run --rm \
  -m 1g \
  --cpus 1 alpine true
# A comment saying docker run alpine is not a command.
docker ps -a; docker rm -v x; docker compose -f x config; docker container ls
[ -x "$entry/docker" ] && printf 'docker %s failed' "$DOCKER" >/dev/null
	# container-limits: exempt only ever passed ps
	out="$(docker "$@" --filter label=x)"
