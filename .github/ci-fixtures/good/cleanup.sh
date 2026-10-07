#!/usr/bin/env bash
# Must pass container-cleanup.sh. Its --rm sits on a continuation line, its -v
# is spelled three ways, and a comment and a volume removal mention the verbs.
# A create carries its own --rm, every docker spelling is held to the same
# rule, an image removal is not a container removal, a word that only contains
# docker does not end a command, and a flag that ends its command just before a
# separator still counts.
# A comment saying docker run mysql:8 is not a command.
docker run -d --name riftal_smoke_fixture \
  -e MYSQL_ROOT_PASSWORD=fixture \
  --rm mysql:8
docker rm -f -v riftal_smoke_fixture
docker rm -fv riftal_smoke_fixture
docker container rm --volumes riftal_smoke_fixture
docker volume rm riftal_smoke_fixture_vol
docker create --rm --name riftal_smoke_fixture mysql:8
$DOCKER run --rm mysql:8 true
"$DOCKER" run --rm mysql:8 true
${DOCKER} rm -v riftal_smoke_fixture >/dev/null 2>&1 || true
"${DOCKER}" container create --rm mysql:8
docker rmi mysql:8
docker run -e HOST=mydocker -v dockerdata:/data --rm mysql:8 true
docker rm -f riftal_smoke_fixture -v; docker volume ls
