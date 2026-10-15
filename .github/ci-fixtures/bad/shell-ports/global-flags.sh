docker --context remote run -d --name mine-h -p 0.0.0.0:19133:19132/udp ghcr.io/riftal-games/riftal-core:0.0.1
nerdctl -n k8s.io run -d --name mine-h -p 0.0.0.0:19133:19132/udp ghcr.io/riftal-games/riftal-core:0.0.1
