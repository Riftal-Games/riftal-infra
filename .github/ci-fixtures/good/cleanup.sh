#!/usr/bin/env bash
# Must pass container-cleanup.sh. Its --rm sits on a continuation line, its -v
# is spelled three ways, and a comment and a volume removal mention the verbs.
# A create carries its own --rm, every docker spelling is held to the same
# rule, an image removal is not a container removal, a word that only contains
# docker does not end a command, and a flag that ends its command just before a
# separator or a trailing comment still counts. Each long-lived service at the
# end is kept by the opt-out line directly above it, whether that line is
# indented with spaces or with tabs, and whether the service continues over
# several lines.
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
docker run --rm mysql:8 true # a trailing comment takes no flag away
docker rm -v riftal_smoke_fixture	# nor after a tab
# container-cleanup: keep a --restart service outlives the script that starts it
docker run -d --restart unless-stopped --name riftal_smoke_fixture mysql:8
if true; then
  # container-cleanup: keep a --restart service outlives the script that starts it
  docker run -d --restart unless-stopped mysql:8
	# container-cleanup: keep	a --restart service outlives the script that starts it
	"$DOCKER" container create --restart always \
		mysql:8
fi
