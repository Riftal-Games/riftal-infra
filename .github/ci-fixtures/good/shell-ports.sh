# Never: docker run -d -p 0.0.0.0:19132:19132/udp ghcr.io/riftal-games/riftal-core:0.0.1
mkdir -p /data/tmp
cp -p a b
grep -P '^[0-9]+$' f
docker exec -it mine-h sh -c 'mkdir -p /data'
docker compose -f stack.yaml up -d
docker run --rm -d -p '127.0.0.1:19132:19132/udp' --network riftal-net "local-pocketmine-mp:$SHA"
docker run --rm --memory-reservation 1g ghcr.io/riftal-games/riftal-core:0.0.1 sh -c mkdir -p /data/tmp
docker run --rm -d -- ghcr.io/riftal-games/riftal-core:0.0.1 -p 19133:19132/udp
