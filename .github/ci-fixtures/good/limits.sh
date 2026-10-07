# Must pass container-limits.sh: each launch has both limits before its image, each other line naming docker is read.
docker run --rm -m 1g --cpus 1 alpine true
docker run --memory=1g --cpus=1 --rm alpine true
docker run -v a:/b -e "A B" --name=x -m1g --cpus 1 alpine true
docker create --memory 2g --cpus 2 alpine
docker run -m 0 --cpus 0 alpine
docker run -d --rm -m 1g --cpus 1 "$@" php:8.3-cli-alpine \
  sh -c true
docker run --rm -m 1g --cpus 1 -v "$1:/plugins:ro" php:8.3-cli-alpine sh -c '
  true
'
docker ps -a --filter "name=^/${own}\$" --format '{{.Names}} ({{.Status}})'
docker rm -v "$id" >/dev/null 2>&1 || true
docker volume create "$vol" >/dev/null || exit 1
docker stop -t 60 "${ids[@]}" >/dev/null
got="$(docker volume inspect -f '{{.CreatedAt}}' "$vol" 2>/dev/null)" || continue
# A comment saying docker run alpine, or `docker run` and `docker`, is no command.
bash .github/scripts/ci-docker-label.sh dockerfiles Dockerfile
	# container-limits: exempt only ever passed ps
	out="$(docker "$@" --filter label=x)"
