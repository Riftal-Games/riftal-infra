#!/usr/bin/env bash
# Self-test for how the instances restart (riftal-infra#355): the restart
# policy and healthcheck in images/compose.yaml, boot-gate.sh and
# raknet-ping.php.
#
# The gate is driven with a stubbed clock, which is how the 120 s cases run
# in seconds. Then the policy compose resolves is run for real on
# php:8.3-cli-alpine: a start that fails at once has to be restarted and then
# parked Up, and one that exits 0, as a `stop` on stdin does, has to stay
# down. Needs docker and jq, as on the self-hosted CI runner.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$DIR/../../compose.yaml"
command -v jq >/dev/null || { printf '::error::jq is required\n'; exit 1; }

work="$(mktemp -d)"
SUFFIX="$$-$(date +%s)"
LOOP="riftal_smoke_355_loop_$SUFFIX"
STOPPED="riftal_smoke_355_stop_$SUFFIX"
cleanup() {
  for c in "$LOOP" "$STOPPED"; do
    docker stop -t 5 "$c" >/dev/null 2>&1 || true
    docker rm -v "$c" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT
printf 'MYSQL_ROOT_PASSWORD=x\nINSTANCE_ID=a\nINSTANCE_B_ID=b\n' > "$work/env"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=20
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

model() { docker compose -f "$1" --env-file "$work/env" config --format json; }
edited() { sed "$1" "$COMPOSE" > "$work/compose.yaml"; model "$work/compose.yaml"; }
B='/^  instance-b:/,/^  backup:/'

printf '\n== every instance restarts on-failure, gated and healthchecked\n'
# PocketMine services that do not restart on bare on-failure, do not run the
# gate first, or are not healthchecked by the RakNet ping after a start period.
ungated() {
  jq -r '.services | to_entries[] | select(.value.image | test("pocketmine"))
    | select(.value.restart != "on-failure"
      or .value.command[0:2] != ["bash", "/plugins/restart/boot-gate.sh"]
      or .value.healthcheck.test != ["CMD", "php", "/plugins/restart/raknet-ping.php"]
      or (.value.healthcheck.start_period // "") == "")
    | .key' <<<"$1"
}
real="$(model "$COMPOSE")"
check "instance and instance-b are the services checked, and both hold" \
  '[ "$(jq -r ".services | to_entries[] | select(.value.image | test(\"pocketmine\")) | .key" \
    <<<"$real" | tr "\n" " ")" = "instance instance-b " ] && [ -z "$(ungated "$real")" ]'
check "a retry cap on instance is caught" \
  '[ "$(ungated "$(edited "0,/restart: on-failure/s//restart: on-failure:5/")")" = instance ]'
check "unless-stopped on instance-b is caught" \
  '[ "$(ungated "$(edited "${B}s/restart: on-failure/restart: unless-stopped/")")" = instance-b ]'
check "instance-b starting without the gate is caught" \
  '[ "$(ungated "$(edited "${B}s#/plugins/restart/boot-gate.sh#/plugins/other.sh#")")" = instance-b ]'
check "instance-b without the RakNet healthcheck is caught" \
  '[ "$(ungated "$(edited "${B}s/healthcheck: \*raknet-health/healthcheck: {test: [CMD, \"true\"]}/")")" = instance-b ]'

printf '\n== boot-gate.sh against a stubbed clock\n'
mkdir -p "$work/bin"
printf '#!/bin/sh\necho "$FAKE_NOW"\n' > "$work/bin/date"
printf '#!/bin/sh\necho "P $*"\n' > "$work/bin/sleep"
chmod +x "$work/bin/date" "$work/bin/sleep"
gate() {
  local now="$1"
  shift
  PATH="$work/bin:$PATH" FAKE_NOW="$now" RIFTAL_BOOT_STARTS="$work/starts" \
    sh "$DIR/boot-gate.sh" "$@" > "$work/out"
}
# One container's starts at the given times from a clean writable layer.
# Prints B for each start that booted and P for each that parked.
runs() {
  local t
  rm -f "$work/starts"
  for t in "$@"; do
    gate "$t" echo B
    tail -n 1 "$work/out" | cut -c1
  done | tr -d '\n'
}
check "three starts inside a few seconds park the third" '[ "$(runs 0 5 10)" = BBP ]'
check "starts each 119 s apart still park" '[ "$(runs 0 119 238)" = BBP ]'
check "a crash after 120 s of uptime restarts, every time" '[ "$(runs 0 121 242 363 484)" = BBBBB ]'
check "one long gap among the last three starts boots" '[ "$(runs 0 5 125 130)" = BBBB ]'
check "a restart long after parking boots, then a fresh loop parks again" \
  '[ "$(runs 0 5 10 900 905 910)" = BBPBBP ]'
check "parking prints the one fixed line and sleeps forever" \
  'runs 0 5 >/dev/null && gate 10 echo B &&
    [ "$(cat "$work/out")" = "RIFTAL BOOT LOOP: 3 starts each under 120 s apart, PocketMine not started, container parked
P infinity" ]'
check "the command runs with its arguments intact" \
  'rm -f "$work/starts" && gate 0 printf "%s|" a "b c" && [ "$(cat "$work/out")" = "a|b c|" ]'
check "start times default to the writable layer, not /data or /plugins" \
  'grep -qx "starts=\"\${RIFTAL_BOOT_STARTS:-/tmp/riftal-boot-starts}\"" "$DIR/boot-gate.sh"'

printf '\n== the resolved policy under a real container runtime\n'
policy="$(jq -r '.services.instance.restart' <<<"$real")"
# tini is the core image's entrypoint; --init stands in for it here.
run_gated() {
  local name="$1"
  shift
  # container-cleanup: keep a --restart policy needs the container to outlive each exit, and cleanup removes it
  docker run -d --init --name "$name" -m 1g --cpus 1 --restart "$policy" \
    -v "$DIR:/gate:ro" php:8.3-cli-alpine sh /gate/boot-gate.sh "$@" >/dev/null
}
state() { docker inspect "$1" --format '{{.State.Status}} {{.State.ExitCode}} {{.RestartCount}}'; }
run_gated "$LOOP" sh -c 'exit 137'
for _ in $(seq 1 30); do
  if docker logs "$LOOP" 2>&1 | grep -q '^RIFTAL BOOT LOOP'; then break; fi
  sleep 1
done
check "a start failing at once is restarted twice, then parked Up" \
  '[ "$(state "$LOOP")" = "running 0 2" ] && [ "$(docker logs "$LOOP" 2>&1 | grep -c "^RIFTAL BOOT LOOP")" = 1 ]'
sleep 3
check "parked, it is not restarted again" '[ "$(state "$LOOP")" = "running 0 2" ]'
check "parked, the RakNet healthcheck fails" '! docker exec "$LOOP" php /gate/raknet-ping.php 2>/dev/null'
run_gated "$STOPPED" sh -c 'exit 0'
sleep 5
check "an exit 0, as from stop, stays down" '[ "$(state "$STOPPED")" = "exited 0 0" ]'

printf '\n== raknet-ping.php against a stand-in server\n'
# Answers one unconnected ping with a pong, the magic replaced when MAGIC=bad.
RESPONDER='$s = stream_socket_server("udp://127.0.0.1:19132", $e, $m, STREAM_SERVER_BIND);
$ping = stream_socket_recvfrom($s, 2048, 0, $peer);
$magic = getenv("MAGIC") === "bad" ? str_repeat("\0", 16) : substr($ping, 9, 16);
$status = "MCPE;riftal-dev;2193;1.26.50;0;20;1;riftal;Survival;1;19132;19133;";
stream_socket_sendto($s, "\x1c" . substr($ping, 1, 8) . pack("J", 7) . $magic
  . pack("n", strlen($status)) . $status, 0, $peer);'
ping_with() {
  docker run --rm --name "riftal_smoke_355_ping_$SUFFIX" -m 1g --cpus 1 -e MAGIC="$1" -e R="$RESPONDER" \
    -v "$DIR:/gate:ro" php:8.3-cli-alpine sh -c "$2" > "$work/ping" 2>&1
}
check "a real pong passes and prints the status string" \
  'ping_with good "php -r \"\$R\" & sleep 1; php /gate/raknet-ping.php" &&
    grep -qx "MCPE;riftal-dev;2193;1.26.50;0;20;1;riftal;Survival;1;19132;19133;" "$work/ping"'
check "a pong without the offline magic fails" \
  '! ping_with bad "php -r \"\$R\" & sleep 1; php /gate/raknet-ping.php"'
check "nothing listening fails" '! ping_with good "php /gate/raknet-ping.php"'

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed\n' "$PASSES"
