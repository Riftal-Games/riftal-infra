# Must fail container-limits.sh at every line: none reads as a launch or as a command that starts none.
docker "$@"
docker $verb alpine
docker container "${verb}" alpine
docker `echo run` alpine
docker $(echo run) alpine
docker --bogus run alpine
docker frobnicate alpine
"$DOCKER_BIN" "$@"
docker compose -f x run app
docker-compose up -d
    container: alpine
    services:
      - uses: docker://alpine
