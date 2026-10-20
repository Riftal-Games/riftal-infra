cmd=(docker run -d --name mine-h)
"${cmd[@]}" -p 0.0.0.0:19133:19132/udp ghcr.io/riftal-games/riftal-core:0.0.1
