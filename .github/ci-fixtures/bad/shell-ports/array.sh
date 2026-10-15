ARGS=(
  -d
  --name mine-h
  -p 0.0.0.0:19133:19132/udp
)
docker run "${ARGS[@]}" ghcr.io/riftal-games/riftal-core:0.0.1
