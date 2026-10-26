#!/usr/bin/env bash
# The harness of the bot-proofs job (ADR 024 item 5, riftal-infra#1088), run by that
# job's harness step alone. It starts no bot: it boots instance A beside MySQL on a job
# network, takes item 2's per-start checks, and answers one hold with the root listing.
#
# Exit status: 0 when every listing was clean, every assertion passed, the expected
# count ran and teardown's listings were empty; 3 when a listing is exposure, whatever
# else failed; 4 when the body ended 0 or 1 with the status otherwise 1, FOUND 0, at
# least one listing taken and every one judged clean, every hold released open, no HOLD
# FAILURE line and no start of "$NODE" recorded (bot-proofs-finish.sh); any other status
# is a failure with no finding. The step turns 0 and 4 into the exposure output none and
# 3 into found, with GITHUB_OUTPUT unset here. A TERM, an INT, the deadline and the
# MySQL wait's `timeout 90` end the script with 124, which is never 4. A `timeout`
# inside a check fails that check, and the `timeout 10` on iptables ends in `|| true`.
# finish ignores TERM and INT, so a finding is 3 past the deadline too; a KILL at
# +120 s ends it with 137, filed pending.
#
# Each condition reaches check single-quoted and is expanded by its eval.
# shellcheck disable=SC2016,SC2034,SC2086,SC1090,SC1091
set -euo pipefail
trap '' PIPE

[ "${GITHUB_ACTIONS:-}" = true ] || { printf '::error::this runs only in GitHub Actions\n'; exit 1; }
ID="${GITHUB_RUN_ID:-}_${GITHUB_RUN_ATTEMPT:-}"
[[ $ID =~ ^[0-9]+_[0-9]+$ ]] || { printf '::error::no run id and attempt\n'; exit 1; }
P=riftal_smoke_ci_$ID
NET=${P}_net DB=${P}_db A=${P}_a VOL=${P}_adata CAP=${P}_cap SETS=${P}_sets IMG=${P}_tool
for name in "$NET" "$DB" "$A" "$VOL" "$CAP" "$SETS" "$IMG"; do
  [[ $name =~ ^riftal_smoke_ci_[0-9]+_[0-9]+_[a-z]+$ && ! $name =~ world|player|backup ]] || { printf '::error::%s is not a name this harness may create\n' "$name"; exit 1; }
done

# The deadline lets teardown and the summary line run before the runner kills the step.
if [ -z "${BOT_PROOFS_INNER:-}" ]; then
  BOT_PROOFS_INNER=1 exec timeout --preserve-status -k 120 600 bash "${BASH_SOURCE[0]}"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/images/core-image.sh"
. "$ROOT/images/devtools-image.sh"
. "$ROOT/.github/scripts/bot-proofs-checks.sh"
. "$ROOT/.github/scripts/bot-proofs-finish.sh"
core_image && devtools_image || exit 1
DT="${RUNNER_TEMP:?}/riftal-devtools" NODE="$DT/node-runtime/bin/node"
[ -x "$NODE" ] || { printf '::error::%s is not the devtools image'"'"'s node\n' "$NODE"; exit 1; }
ETH0="$(eth0_address)" || { printf '%s\n' "$ETH0"; exit 1; }

# PocketMine prints every severity as [<thread>/<LEVEL>].
SEVERE='/(EMERGENCY|ALERT|CRITICAL|ERROR)\]'
EXPECTED_ASSERTIONS=13 FOUND=0 PASSES=0 FAILURES=0 spid=""
work="$(mktemp -d)" LOG="$work/a.log"
PW="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# $1 what is claimed; $2 a condition, evaluated
check() {
  if eval "$2"; then PASSES=$((PASSES + 1)); printf 'ok   %s\n' "$1"
  else FAILURES=$((FAILURES + 1)); printf 'FAIL %s\n' "$1"; fi
}

residue() {
  local kind out
  for kind in "ps -a --format {{.Names}}" "volume ls --format {{.Name}}" "network ls --format {{.Name}}" "images --format {{.Repository}}"; do
    out="$(docker $kind)" || return 2
    grep -E "^${P}_" <<<"$out" | sed "s|^|${kind%% *}: |" || true
  done
}

halt() {
  [ -n "$spid" ] || return 0
  echo stop >&3 || true
  for _ in $(seq 1 300); do kill -0 "$spid" 2>/dev/null || break; sleep 0.2; done
  exec 3>&-
  # SIGTERM is the server's own graceful stop; nothing here kills it.
  ! kill -0 "$spid" 2>/dev/null || docker stop -t 30 "$A" >/dev/null 2>&1 || true
  wait "$spid" || true
  spid=""
  tail -n 4 "$LOG" | sed 's/^/  A | /'
  check "A stopped on stdin, logged its shutdown and nothing above WARNING" \
    'grep -qF "Stopping other threads" "$LOG" && ! grep -qE "$SEVERE" "$LOG"'
}

teardown() {
  local left=""
  halt
  docker stop -t 30 "$DB" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    docker rm -v "$DB" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm "$VOL" "$CAP" "$SETS" >/dev/null 2>&1 || true
    docker image rm "$IMG:head" >/dev/null 2>&1 || true
    left="$(residue)" || left="docker could not list"
    [ -n "$left" ] || break
    sleep 1
  done
  printf 'teardown listings filtered on %s_: %s\n' "$P" "${left:-empty}"
  check "teardown's container, volume, network and image listings are empty" '[ -z "$left" ]'
  rm -rf "$work"
}

finish() {
  local rc=$? status ran
  set +e
  trap '' TERM INT; trap - EXIT
  read_hold_log "$work/hold.log"
  read_records "$work/runners"
  teardown
  ran=$((PASSES + FAILURES))
  status="$(finish_status "$rc")" || status=1
  printf 'harness status %s after %ss, %s of %s assertions ran, %s passed, %s failed, listings exposure: %s, judged clean: %s of %s, starts recorded: %s\n' "$status" "$SECONDS" "$ran" "$EXPECTED_ASSERTIONS" "$PASSES" "$FAILURES" "$FOUND" "$LISTINGS_CLEAN" "$LISTINGS" "$RUNNERS"
  exit "$status"
}
trap finish EXIT; trap 'exit 124' TERM INT

cat >"$work/probe.js" <<'JS'
const dgram = require('dgram')
const { ping, pongServerString } = require(`${process.env.DT}/distro-probe`)
const { rootHold, parseInstance } = require(`${process.env.DT}/root-listing`)
const { takeListing } = require(`${process.env.DT}/socket-listing`)

async function hold () {
  const sock = dgram.createSocket('udp4')
  const held = await new Promise(resolve => sock.bind(0, '127.0.0.1', () => resolve(sock.address().port)))
  console.log(`RUNNER pid=${process.pid} port=${held}`)
  const listing = await takeListing({ platform: 'linux', pid: process.pid, liveBots: 1 })
  console.log(`RUNNER LISTING ${listing.verdict}: ${listing.reason}`)
  const e = process.env
  const h = rootHold({ image: e.IMAGE, nameFor: n => `${e.PREFIX}_rootlisting_${n}`, eth0: e.ETH0, instances: [parseInstance(e.INSTANCE)], maxHolds: 1, command: args => ({ file: 'docker', args, timeoutMs: 40000 }) })
  const answer = await h.answer(1, { port: held }, listing)
  let state = 'open'
  try { sock.address() } catch { state = 'closed' }
  console.log(`${answer} 1\nPROBE RELEASED 1 ${held} ${state}`)
  const failures = h.failures({ released: new Map([[1, state]]), done: { holds: 1, ports: [held] } })
  failures.forEach(f => console.log(`HOLD FAILURE ${f}`))
  process.exit(failures.length === 0 ? 0 : failures.some(f => f.includes(' exposed')) ? 3 : 1)
}

const [mode, port] = process.argv.slice(2)
if (mode === 'ping') {
  ping('127.0.0.1', Number(port), 5000).then(msg => { console.log(`PONG ${pongServerString(msg)}`); process.exit(pongServerString(msg) ? 0 : 1) })
} else hold()
JS

# Every "$NODE" start after this is recorded before node runs, except a start whose
# first argument is exactly "$work/probe.js" and a start whose whole argument list is
# exactly --version. A record that cannot be written refuses the start.
cat >"$work/node" <<SH
#!/usr/bin/env bash
. "$ROOT/.github/scripts/bot-proofs-finish.sh"
record_node_start "$work/probe.js" "$work/runners" "\$@" || exit 125
exec "$NODE" "\$@"
SH
chmod +x "$work/node"
NODE="$work/node"

PRHEAD="$(git -C "$ROOT" cat-file -p HEAD | awk '/^parent /&&++n==2{print $2}' || true)"
printf 'run %s, pr head %s, checkout %s, runner %s, eth0 %s, expecting %s assertions\n' "$ID" "${PRHEAD:-${GITHUB_SHA:-unknown}}" "${GITHUB_SHA:-unknown}" "${RUNNER_NAME:-unknown}" "$ETH0" "$EXPECTED_ASSERTIONS"
for image in "$CORE_IMAGE" "$DEVTOOLS_IMAGE"; do printf 'image %s %s\n' "$image" "$(docker image inspect --format '{{.Id}}' "$image")"; done
printf 'node %s\n' "$("$NODE" --version)"

docker build -q --label "riftal.ci.job=${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${GITHUB_JOB:-job}" -t "$IMG:head" "$ROOT/images/backup" >/dev/null
docker network create "$NET" >/dev/null
for vol in "$VOL" "$CAP" "$SETS"; do docker volume create "$vol" >/dev/null; done
docker run -d --rm --name "$DB" -m 1g --cpus 1 --network "$NET" --network-alias db \
  -e MYSQL_ROOT_PASSWORD="$PW" -e MYSQL_DATABASE=riftal_smoke_ci mysql:8 >/dev/null
timeout 90 bash -c 'until docker exec "$0" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; do sleep 1; done' "$DB"
check "the backup image reaches MySQL over the job network and writes both volumes" \
  'docker run --rm -m 1g --cpus 1 --network "$NET" -e MYSQL_PWD="$PW" -v "$SETS:/b" -v "$CAP:/c" "$IMG:head" \
     bash -c "mysql -h db -uroot -e \"SELECT 1\" >/dev/null && touch /b/t /c/t && rm /b/t /c/t"'

mkdir "$work/plugins" && cp "$ROOT/images/plugins/RiftalCapture.php" "$ROOT/images/plugins/RiftalDevBots.php" "$work/plugins/"
chmod -R a+rX "$work"
mkfifo "$work/in"
docker run --rm -i --name "$A" -m 2g --cpus 2 --network "$NET" -p 127.0.0.1::19132/udp \
  -v "$VOL:/data" -v "$work/plugins:/plugins:ro" -v "$CAP:/capture:ro" -e RIFTAL_DEV_ENV=1 \
  -e "POCKETMINE_ARGS=--level-type=flat --xbox-auth=false --riftal-dev-bots=on --auto-report.enabled=0" \
  "$CORE_IMAGE" start-pocketmine <"$work/in" >"$LOG" 2>&1 &
spid=$!; exec 3>"$work/in"
check "A reaches LOADS: Done, RiftalCapture and RiftalDevBots enabled, nothing above WARNING" \
  'timeout 120 bash -c "until grep -qF \"Done (\" $LOG; do sleep 0.2; done" && grep -q "Enabling RiftalCapture" "$LOG" && grep -q "Enabling RiftalDevBots" "$LOG" &&
   ! grep -qE "$SEVERE" "$LOG"'
[ "$FAILURES" -eq 0 ] || { tail -n 40 "$LOG"; exit 1; }

# ADR 024 item 2: read at this start of A, after its LOADS and before any bot connects.
port='(index (index .NetworkSettings.Ports "19132/udp") 0)'
INSPECT="$(docker inspect -f "HostIp={{$port.HostIp}} HostPort={{$port.HostPort}} Memory={{.HostConfig.Memory}} NanoCpus={{.HostConfig.NanoCpus}} Cmd={{json .Config.Cmd}} Env={{json .Config.Env}}" "$A")"
printf 'A: %s\n' "$INSPECT"
H="$(sed -E 's/.* HostPort=([0-9]+) .*/\1/' <<<"$INSPECT")"
C="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$A")"
GW="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")"
BR="br-$(docker network inspect -f '{{.Id}}' "$NET" | cut -c1-12)"
RAW="$(timeout 10 sudo -n iptables -t raw -S PREROUTING || true)"
printf 'ip_forward=%s, A at %s behind %s on %s, raw table:\n%s\n' "$(cat /proc/sys/net/ipv4/ip_forward)" "$C" "$GW" "$BR" "$RAW"
check "A publishes 19132/udp on 127.0.0.1 and a host port Docker chose, under -m 2g --cpus 2" \
  'grep -qE "^HostIp=127\.0\.0\.1 HostPort=[0-9]+ Memory=2147483648 NanoCpus=2000000000 " <<<"$INSPECT"'
check "A started with xbox-auth off, dev bots on, crash upload off and RIFTAL_DEV_ENV=1" \
  'grep -qF -- "--xbox-auth=false --riftal-dev-bots=on --auto-report.enabled=0" <<<"$INSPECT" && grep -qF "RIFTAL_DEV_ENV=1" <<<"$INSPECT"'
check "route_localnet=0 on eth0 and on $BR" \
  '[ "$(cat /proc/sys/net/ipv4/conf/{eth0,$BR}/route_localnet | tr -d "\n")" = 00 ]'
check "Docker drops traffic to $C that does not arrive on $BR" 'grep -qxF -- "-A PREROUTING -d $C/32 ! -i $BR -j DROP" <<<"$RAW"'
check "a ping of 127.0.0.1:$H answers" 'DT="$DT" "$NODE" "$work/probe.js" ping "$H"'
[ "$FAILURES" -eq 0 ] || exit 1

rc=0
DT="$DT" IMAGE="$DEVTOOLS_IMAGE" PREFIX="$P" ETH0="$ETH0" INSTANCE="$H,$C,$GW" "$NODE" "$work/probe.js" hold >"$work/hold.log" 2>&1 || rc=$?
sed 's/^/  | /' "$work/hold.log"
[ "$rc" -ne 3 ] || FOUND=1
read -r RPID RPORT < <(sed -n 's/^RUNNER pid=\([0-9]*\) port=\([0-9]*\)$/\1 \2/p' "$work/hold.log") || true
printf 'sockets in the root listing with no owning process on :323, which decide nothing here:\n'
{ grep -E '[:]323 ' "$work/hold.log" | grep -v 'users:' || true; } | sed 's/^/  /'
check "the root listing was judged clean" '[ "$rc" = 0 ]'
check "hold 1 was answered probed and released open on port ${RPORT:-none}" \
  'grep -qx "probed 1" "$work/hold.log" && grep -qx "PROBE RELEASED 1 ${RPORT:-0} open" "$work/hold.log"'
check "the root listing attributes 127.0.0.1:$H to docker-proxy" \
  'grep -qE "127\.0\.0\.1:$H +[0-9.*:]+ +users:\(\(\"docker-proxy\",pid=" "$work/hold.log"'
check "the root listing attributes 127.0.0.1:${RPORT:-none} to this runner's process, pid ${RPID:-none}" \
  'grep -qE "127\.0\.0\.1:${RPORT:-0} +[0-9.*:]+ +users:\(\(\"[^\"]+\",pid=${RPID:-0}," "$work/hold.log"'
