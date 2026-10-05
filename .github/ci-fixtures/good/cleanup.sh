#!/usr/bin/env bash
# Must pass container-cleanup.sh. Its --rm sits on a continuation line, its -v
# is spelled three ways, and a comment and a volume removal mention the verbs.
# A comment saying docker run mysql:8 is not a command.
docker run -d --name riftal_smoke_fixture \
  -e MYSQL_ROOT_PASSWORD=fixture \
  --rm mysql:8
docker rm -f -v riftal_smoke_fixture
docker rm -fv riftal_smoke_fixture
docker container rm --volumes riftal_smoke_fixture
docker volume rm riftal_smoke_fixture_vol
