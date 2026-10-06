#!/usr/bin/env bash
# Must pass container-cleanup.sh. Its --rm sits on a continuation line, its -v
# is spelled three ways, and a comment and a volume removal mention the verbs.
# A create carries its own --rm, `$DOCKER` and `${DOCKER}` are held to the same
# rule, and a restarting service is kept under an opt-out with its reason.
# A comment saying docker run mysql:8 is not a command.
docker run -d --name riftal_smoke_fixture \
  -e MYSQL_ROOT_PASSWORD=fixture \
  --rm mysql:8
docker rm -f -v riftal_smoke_fixture
docker rm -fv riftal_smoke_fixture
docker container rm --volumes riftal_smoke_fixture
docker volume rm riftal_smoke_fixture_vol
docker create --rm --name riftal_smoke_fixture mysql:8
"$DOCKER" run --rm mysql:8 true
${DOCKER} rm -v riftal_smoke_fixture >/dev/null 2>&1 || true
# container-cleanup: keep docker refuses --rm with --restart, and this service must survive a daemon restart
docker run -d --restart unless-stopped --name riftal_smoke_fixture mysql:8
docker rm -f -v riftal_smoke_fixture
