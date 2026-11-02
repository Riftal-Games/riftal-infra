#!/usr/bin/env bash
# The harness of the bot-proofs job (ADR 024 item 5, riftal-infra#1088), run by that
# job's harness step alone. It boots instances A and B beside MySQL on a job network,
# takes item 2's per-start checks at every start of either, answers one hold with the
# root listing, and plays ADR 015 proof 1 with bots against the head's backup.sh and
# again against a mutant of it, proof 3 the same way, proof 10's held run, then proof 1
# against main's merge-base script through a tar shim while that script has no capture
# request, then proof 6's twenty runs with a bot mining, proof 8's cost run, and proof
# 10's clean-stop run and its mutant.
#
# Exit status: 0 when every listing was clean, every assertion passed, the expected
# count ran, teardown's listings were empty and every recorded runner was clean; 3 when
# a listing is exposure, whatever else failed; 4 when the body ended 0 or 1 with the
# status otherwise 1, FOUND 0, at least one listing taken and every one judged clean,
# every hold released open, no HOLD FAILURE line and every recorded start of "$NODE" a
# clean runner (bot-proofs-finish.sh); any other status is a failure with no finding.
# The step turns 0 and 4 into the exposure output none and
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
RDB=${P}_rdb RVOL=${P}_rvol BK=${P}_bk SHIM=${P}_shim B=${P}_b BVOL=${P}_bdata R=${P}_r
for name in "$NET" "$DB" "$A" "$VOL" "$CAP" "$SETS" "$IMG" "$RDB" "$RVOL" "$BK" "$SHIM" "$B" "$BVOL" "$R"; do
  [[ $name =~ ^riftal_smoke_ci_[0-9]+_[0-9]+_[a-z]+$ && ! $name =~ world|player|backup ]] || { printf '::error::%s is not a name this harness may create\n' "$name"; exit 1; }
done

# The deadline lets teardown and the summary line run before the runner kills the step.
if [ -z "${BOT_PROOFS_INNER:-}" ]; then
  BOT_PROOFS_INNER=1 exec timeout --preserve-status -k 120 1500 bash "${BASH_SOURCE[0]}"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/images/core-image.sh"
. "$ROOT/images/devtools-image.sh"
. "$ROOT/.github/scripts/bot-proofs-checks.sh"
. "$ROOT/.github/scripts/bot-proofs-finish.sh"
. "$ROOT/.github/scripts/bot-proofs-runner-logs.sh"
. "$ROOT/.github/scripts/capture-cost.sh"
core_image && devtools_image || exit 1
DT="${RUNNER_TEMP:?}/riftal-devtools" NODE="$DT/node-runtime/bin/node"
[ -x "$NODE" ] || { printf '::error::%s is not the devtools image'"'"'s node\n' "$NODE"; exit 1; }
ETH0="$(eth0_address)" || { printf '%s\n' "$ETH0"; exit 1; }

# The control runs main's merge-base script, which the job fetched ahead of this step,
# only while that script has no capture request.
BASE_SH="${RUNNER_TEMP:?}/merge-base/backup.sh" CONTROL=0
[ -s "$BASE_SH" ] || { printf '::error::no merge-base deploy/backup.sh at %s\n' "$BASE_SH"; exit 1; }
grep -qF CAPTURE_DIR "$BASE_SH" || CONTROL=1

# PocketMine prints every severity as [<thread>/<LEVEL>].
SEVERE='/(EMERGENCY|ALERT|CRITICAL|ERROR)\]'
EXPECTED_ASSERTIONS=$((83 + 5 * CONTROL)) FOUND=0 PASSES=0 FAILURES=0 spid="" bspid="" rspid="" LOGB="" LOGR="" NA=1 NB=0 under="" RED=""
work="$(mktemp -d)" LOG="$work/a.log"
PRINTED="$work/printed"
PW="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# $1 what is claimed; $2 a condition, evaluated. Under a mutant a failure is
# collected in RED instead of counted.
check() {
  if eval "$2"; then
    [ -n "$under" ] || { PASSES=$((PASSES + 1)); printf 'ok   %s\n' "$1"; }
  elif [ -n "$under" ]; then
    RED+="red under $under: $1"$'\n'
  else
    FAILURES=$((FAILURES + 1)); printf 'FAIL %s\n' "$1"
  fi
}

residue() {
  local kind out
  for kind in "ps -a --format {{.Names}}" "volume ls --format {{.Name}}" "network ls --format {{.Name}}" "images --format {{.Repository}}"; do
    out="$(docker $kind)" || return 2
    grep -E "^${P}_" <<<"$out" | sed "s|^|${kind%% *}: |" || true
  done
}

# $1 the variable holding the server's pid, $2 its stdin descriptor, $3 its container, $4 its log.
halt() {
  local -n pid=$1
  local label=${3##*_} log=$4
  [ -n "$pid" ] || return 0
  echo stop >&"$2" || true
  for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  eval "exec $2>&-"
  # A server still up after its stop on stdin gets SIGTERM, its own graceful stop,
  # and docker stop sends SIGKILL once 30 s have passed.
  ! kill -0 "$pid" 2>/dev/null || docker stop -t 30 "$3" >/dev/null 2>&1 || true
  wait "$pid" || true
  pid=""
  tail -n 4 "$log" | sed "s/^/  ${label^^} | /"
  check "${label^^} stopped on stdin, logged its shutdown and nothing above WARNING" \
    'grep -qF "Stopping other threads" "$log" && ! grep -qE "$SEVERE" "$log"'
}

teardown() {
  local left=""
  print_unprinted_runners "$work/runners" "$work/hold.log" "$LOG"
  raklib_lines "$work" "before stop"
  halt spid 3 "$A" "$LOG"
  halt bspid 4 "$B" "$LOGB"
  halt rspid 5 "$R" "$LOGR"
  raklib_lines "$work" "after stop"
  docker stop -t 30 "$DB" "$RDB" "$BK" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    docker rm -v "$DB" "$RDB" "$BK" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm "$VOL" "$BVOL" "$CAP" "$SETS" "$RVOL" "$SHIM" >/dev/null 2>&1 || true
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
  read_records "$work/runners" "$work/hold.log" "$LOG"
  teardown
  ran=$((PASSES + FAILURES))
  status="$(finish_status "$rc")" || status=1
  printf 'harness status %s after %ss, %s of %s assertions ran, %s passed, %s failed, listings exposure: %s, judged clean: %s of %s, runners clean: %s of %s\n' "$status" "$SECONDS" "$ran" "$EXPECTED_ASSERTIONS" "$PASSES" "$FAILURES" "$FOUND" "$LISTINGS_CLEAN" "$LISTINGS" "$RUNNERS_CLEAN" "$RUNNERS"
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
  const h = rootHold({ image: e.IMAGE, nameFor: n => `${e.PREFIX}_rootlisting_${n}`, eth0: e.ETH0, instances: e.INSTANCE.split(';').map(parseInstance), maxHolds: 1, command: args => ({ file: 'docker', args, timeoutMs: 40000 }) })
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
if [ "$CONTROL" = 1 ]; then
  printf 'control runs: merge base %s of main has no capture request\n' "$(cat "${BASE_SH%/*}/sha")"
else
  printf 'control skipped: merge base %s of main has the capture request\n' "$(cat "${BASE_SH%/*}/sha")"
fi

docker build -q --label "riftal.ci.job=${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${GITHUB_JOB:-job}" -t "$IMG:head" "$ROOT/images/backup" >/dev/null
docker network create "$NET" >/dev/null
for vol in "$VOL" "$BVOL" "$CAP" "$SETS" "$SHIM"; do docker volume create "$vol" >/dev/null; done
docker run -d --rm --name "$DB" -m 1g --cpus 1 --network "$NET" --network-alias db \
  -e MYSQL_ROOT_PASSWORD="$PW" -e MYSQL_DATABASE=riftal_smoke_ci mysql:8 >/dev/null
timeout 90 bash -c 'until docker exec "$0" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; do sleep 1; done' "$DB"
docker exec -i -e MYSQL_PWD="$PW" "$DB" mysql -uroot riftal_smoke_ci <"$ROOT/deploy/fence-fixture.sql"
check "the backup image reaches MySQL over the job network and writes both volumes" \
  'docker run --rm -m 1g --cpus 1 --network "$NET" -e MYSQL_PWD="$PW" -v "$SETS:/b" -v "$CAP:/c" "$IMG:head" \
     bash -c "mysql -h db -uroot -e \"SELECT 1\" >/dev/null && touch /b/t /c/t && rm /b/t /c/t"'

mkdir "$work/plugins" && cp "$ROOT/images/plugins/RiftalCapture.php" "$ROOT/images/plugins/RiftalDevBots.php" "$work/plugins/"
chmod -R a+rX "$work"
# $1 a container, $2 its volume, $3 its log, $4 its stdin descriptor, $5 the variable for
# its pid. Starts it, asserts its LOADS, and takes ADR 024 item 2's checks of this start
# before any bot connects to it. Sets NH, its host port, and NC, its address on the job network.
up() {
  local -n pid=$5
  local log=$3 fifo="$work/in$4" label=${1##*_} inspect raw port='(index (index .NetworkSettings.Ports "19132/udp") 0)'
  label=${label^^}
  [ -p "$fifo" ] || mkfifo "$fifo"
  docker run --rm -i --name "$1" -m 2g --cpus 2 --network "$NET" -p 127.0.0.1::19132/udp \
    -v "$2:/data" -v "$work/plugins:/plugins:ro" -v "$CAP:/capture:ro" -e RIFTAL_DEV_ENV=1 \
    -e "POCKETMINE_ARGS=--level-type=flat --xbox-auth=false --riftal-dev-bots=on --auto-report.enabled=0 --ticks-per.autosave=200" \
    "$CORE_IMAGE" start-pocketmine <"$fifo" >"$log" 2>&1 &
  pid=$!
  eval "exec $4>\"$fifo\""
  check "$label reaches LOADS: Done, RiftalCapture and RiftalDevBots enabled, nothing above WARNING" \
    'timeout 120 bash -c "until grep -qF \"Done (\" $log; do sleep 0.2; done" && grep -q "Enabling RiftalCapture" "$log" && grep -q "Enabling RiftalDevBots" "$log" &&
     ! grep -qE "$SEVERE" "$log"'
  [ "$FAILURES" -eq 0 ] || { tail -n 40 "$log"; exit 1; }
  inspect="$(docker inspect -f "HostIp={{$port.HostIp}} HostPort={{$port.HostPort}} Memory={{.HostConfig.Memory}} NanoCpus={{.HostConfig.NanoCpus}} Cmd={{json .Config.Cmd}} Env={{json .Config.Env}}" "$1")"
  printf '%s: %s\n' "$label" "$inspect"
  NH="$(sed -E 's/.* HostPort=([0-9]+) .*/\1/' <<<"$inspect")"
  NC="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$1")"
  GW="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")"
  BR="br-$(docker network inspect -f '{{.Id}}' "$NET" | cut -c1-12)"
  raw="$(timeout 10 sudo -n iptables -t raw -S PREROUTING || true)"
  printf 'ip_forward=%s, %s at %s behind %s on %s, raw table:\n%s\n' "$(cat /proc/sys/net/ipv4/ip_forward)" "$label" "$NC" "$GW" "$BR" "$raw"
  check "$label publishes 19132/udp on 127.0.0.1 and a host port Docker chose, under -m 2g --cpus 2" \
    'grep -qE "^HostIp=127\.0\.0\.1 HostPort=[0-9]+ Memory=2147483648 NanoCpus=2000000000 " <<<"$inspect"'
  check "$label started with xbox-auth off, dev bots on, crash upload off and RIFTAL_DEV_ENV=1" \
    'grep -qF -- "--xbox-auth=false --riftal-dev-bots=on --auto-report.enabled=0" <<<"$inspect" && grep -qF "RIFTAL_DEV_ENV=1" <<<"$inspect"'
  check "$label: route_localnet=0 on eth0 and on $BR" \
    '[ "$(cat /proc/sys/net/ipv4/conf/{eth0,$BR}/route_localnet | tr -d "\n")" = 00 ]'
  check "$label: Docker drops traffic to $NC that does not arrive on $BR" 'grep -qxF -- "-A PREROUTING -d $NC/32 ! -i $BR -j DROP" <<<"$raw"'
  check "$label: a ping of 127.0.0.1:$NH answers" 'DT="$DT" "$NODE" "$work/probe.js" ping "$NH"'
  [ "$FAILURES" -eq 0 ] || exit 1
}

up "$A" "$VOL" "$LOG" 3 spid
H=$NH C=$NC
LOGB="$work/b$((++NB)).log"
up "$B" "$BVOL" "$LOGB" 4 bspid
HB=$NH CB=$NC

rc=0
DT="$DT" IMAGE="$DEVTOOLS_IMAGE" PREFIX="$P" ETH0="$ETH0" INSTANCE="$H,$C,$GW;$HB,$CB,$GW" "$NODE" "$work/probe.js" hold >"$work/hold.log" 2>&1 || rc=$?
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
check "the root listing attributes 127.0.0.1:$HB to docker-proxy" \
  'grep -qE "127\.0\.0\.1:$HB +[0-9.*:]+ +users:\(\(\"docker-proxy\",pid=" "$work/hold.log"'
check "the root listing attributes 127.0.0.1:${RPORT:-none} to this runner's process, pid ${RPID:-none}" \
  'grep -qE "127\.0\.0\.1:${RPORT:-0} +[0-9.*:]+ +users:\(\(\"[^\"]+\",pid=${RPID:-0}," "$work/hold.log"'
[ "$FOUND" = 0 ] || exit 3
[ "$FAILURES" -eq 0 ] || exit 1

# ADR 015 proof 1. A held volume's players/ comes from the stage of the held
# tick, so a stack dropped and picked up during the stall is in p1a's file once
# and in p1b's not at all.
STALL=90
# $1 a literal string; $2 a file; $3 seconds to wait for the string in it
await() { timeout "$3" bash -c 'until grep -qF -- "$0" "$1" 2>/dev/null; do sleep 0.2; done' "$1" "$2"; }

# An exposure ends the run with exit 3 ahead of any failure, and a failure ends it
# before another bot connects.
gate() { [ "$FOUND" = 0 ] || exit 3; [ "$FAILURES" -eq 0 ] || { tail -n 60 "$LOG"; exit 1; }; }

# Counts the minecraft:dirt entries of each named bot's saved inventory on /v.
cat >"$work/count.js" <<'JS'
const fs = require('fs')
const zlib = require('zlib')
const nbt = require('/devtools/node_modules/prismarine-nbt')
;(async () => {
  for (const name of process.argv.slice(2)) {
    const file = `/v/players/${name}.dat`
    const held = fs.existsSync(file) ? nbt.simplify((await nbt.parse(zlib.gunzipSync(fs.readFileSync(file)), 'big')).parsed).Inventory ?? [] : []
    console.log(`${name} ${held.filter(i => i.Name === 'minecraft:dirt').length}`)
  }
})()
JS

# $1 a scenario, $2 its bots' count, $3 an instance's container, $4 its host port, $5 the
# scenario's log. Both instances stand in its listings. Sets BPID.
bots() {
  BOT_PORT="$4" timeout 240 "$NODE" "$DT/run-scenario.js" "$1" --container "$3" --engine docker \
    --in-distro --max-holds "$2" --hold-budget-sec 60 --listing-image "$DEVTOOLS_IMAGE" --listing-name-prefix "$P" \
    --eth0 "$ETH0" --instance "$H,$C,$GW" --instance "$HB,$CB,$GW" >"$5" 2>&1 </dev/null &
  BPID=$!
}

# $1 the bots' log. Starts proof 1's bots on a fresh pair of saved files and sets BPID.
p1_bots() {
  docker run --rm -m 1g --cpus 1 -v "$VOL:/d" "$IMG:head" rm -f /d/players/p1a.dat /d/players/p1b.dat
  rm -f "$work/stall" "$work/end"
  CAPTURE_STALL_FILE="$work/stall" CAPTURE_END_FILE="$work/end" bots capture-stall-drop-pickup 2 "$A" "$H" "$1"
}

# $1 a volume, the rest the bots' names. Prints each one's count of dirt stacks in its saved file there.
stacks() {
  docker run --rm -m 1g --cpus 1 -v "$1:/v:ro" -v "$work/count.js:/count.js:ro" "$DEVTOOLS_IMAGE" \
    /devtools/node-runtime/bin/node /count.js "${@:2}" || true
}

# $1 the backup script, $2 its request id, $3 the volume mount it tars, $4 its log. Starts
# it with the stall and leaves it running.
backup_run() {
  docker run --rm --name "$BK" -m 1g --cpus 1 --network "$NET" \
    -v "$1:/deploy/backup.sh:ro" -v "$SETS:/backups" -v "$CAP:/capture" -v "$3" \
    -e MYSQL_HOST=db -e MYSQL_USER=root -e MYSQL_PASSWORD="$PW" -e MYSQL_DATABASE=riftal_smoke_ci \
    -e CAPTURE_TEST_REQUEST_ID="$2" -e CAPTURE_TEST_STALL_SECONDS="$STALL" \
    "$IMG:head" bash /deploy/backup.sh >"$4" 2>&1 &
}

# $1 a tag for the run's files; $2 the backup script to run; $3 its request id.
# Sets BRC, JRC and EARLY, the last being 1 when the tars began before the bots finished.
p1_run() {
  local bots="$work/$1-bots.log" bk="$work/$1-bk.log" bpid jpid
  p1_bots "$bots"
  bpid=$BPID
  await "CAPTURE WAIT stall" "$bots" 120 || true
  backup_run "$2" "$3" "$VOL:/worlds/a:ro" "$bk"
  jpid=$!
  await "capture $3 held" "$LOG" 60 || true
  touch "$work/stall"
  BRC=0; wait "$bpid" || BRC=$?
  [ "$BRC" -ne 4 ] || FOUND=1
  EARLY=0; ! grep -qF "snapshotting world volume" "$bk" || EARLY=1
  touch "$work/end"
  JRC=0; wait "$jpid" || JRC=$?
  print_runner bots "$bots"
  sed 's/^/  run | /' "$bk"
}

# $1 the run's tag. Sets SET to the set the run completed and MANIFEST to its manifest,
# both empty when the run wrote none.
manifest_of() {
  SET="$(sed -n 's|.*complete at /backups/||p' "$work/$1-bk.log")"
  MANIFEST="$(docker run --rm -m 1g --cpus 1 -v "$SETS:/b:ro" "$IMG:head" cat "/b/$SET/manifest.txt" || true)"
}

# $1 the run's tag, $2 the letter of the volume its set holds, the rest the bots' names.
# Restores the set onto a fresh volume with the head's restore.sh, then reads the
# manifest and the restored inventories. The volume stays when KEEP is set.
restore_set() {
  manifest_of "$1"
  docker volume create "$RVOL" >/dev/null
  docker run --rm -m 1g --cpus 1 --network "$NET" -v "$ROOT/deploy/restore.sh:/deploy/restore.sh:ro" \
    -v "$SETS:/backups:ro" -v "$RVOL:/worlds/$2" -e MYSQL_HOST=rdb -e MYSQL_USER=root -e MYSQL_PASSWORD="$PW" \
    -e MYSQL_DATABASE=riftal_smoke_ci -e BACKUP_SET="/backups/$SET" "$IMG:head" bash /deploy/restore.sh 2>&1 | sed 's/^/  restore | /' || true
  STACKS="$(stacks "$RVOL" "${@:3}")"
  [ -n "${KEEP:-}" ] || docker volume rm "$RVOL" >/dev/null
  printf 'manifest:\n%s\nrestored dirt stacks: %s\n' "$MANIFEST" "$(tr '\n' ' ' <<<"$STACKS")"
}

# $1 the run's tag; $2 its request id
p1_judge() {
  TAG="$1" RID="$2"
  restore_set "$TAG" a p1a p1b
  check "[p1-bots] proof 1's bots passed behind clean holds inside the stall, and the run completed" \
    '[ "$BRC" = 0 ] && grep -q "^SCENARIO PASS capture-stall-drop-pickup" "$work/$TAG-bots.log" && [ "$EARLY" = 0 ] && [ "$JRC" = 0 ]'
  check "[p1-manifest] 1. the manifest marks A held $RID" 'grep -qxF "capture_mode.a: held $RID" <<<"$MANIFEST"'
  check "[p1-stacks] 1. the restored set holds exactly one stack in p1a's file and none in p1b's" \
    'grep -qx "p1a 1" <<<"$STACKS" && grep -qx "p1b 0" <<<"$STACKS"'
}

docker run -d --rm --name "$RDB" -m 1g --cpus 1 --network "$NET" --network-alias rdb \
  -e MYSQL_ROOT_PASSWORD="$PW" mysql:8 >/dev/null
p1_run head "$ROOT/deploy/backup.sh" "p1-$ID"
timeout 90 bash -c 'until docker exec "$0" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; do sleep 1; done' "$RDB"
p1_judge head "p1-$ID"
gate

# The held volume's tar reads the live players/ in place of the stage, so the
# restored set holds what the bots left: p1b's stack, and none in p1a's file.
sed 's|-C "$vol/.capture/$request_id" players|-C "$vol" players|' "$ROOT/deploy/backup.sh" >"$work/stage-ignored.sh"
printf '\n== mutant stage-ignored, against proof 1\n'
diff "$ROOT/deploy/backup.sh" "$work/stage-ignored.sh" || true
under=stage-ignored
if ! cmp -s "$ROOT/deploy/backup.sh" "$work/stage-ignored.sh"; then
  p1_run mut "$work/stage-ignored.sh" "p1m-$ID"
  p1_judge mut "p1m-$ID"
fi
under=""
printf '%s' "$RED"
check "mutant stage-ignored turns only [p1-stacks] red, with p1b's file holding the stack" \
  '[ "$(grep -c "^red under" <<<"$RED")" = 1 ] && grep -q "^red under stage-ignored: \[p1-stacks\]" <<<"$RED" && grep -qx "p1b 1" <<<"$STACKS"'

# ADR 015 proof 3. B is down when the run asks for its hold, so the run lists it as
# stopped. B starts during the stall; the run must see the volume differ, wait on it
# again under the held request, and tar it as held, with the stage of the held tick,
# in which p3a still holds the stack.
gate

# $1 a tag for the run's files; $2 the backup script to run; $3 its request id.
# B is running when this starts and again when it ends. Sets BRC, JRC and EARLY as p1_run does.
# Its checks count under a mutant too, since a failure of any of them must stop the bots.
p3_run() {
  local seed="$work/$1-seed.log" bots="$work/$1-bots.log" bk="$work/$1-bk.log" jpid keep=$under
  under=""
  docker run --rm -m 1g --cpus 1 -v "$BVOL:/d" "$IMG:head" rm -f /d/players/p3a.dat /d/players/p3b.dat
  bots capture-stall-seed-stack 1 "$B" "$HB" "$seed"
  SRC=0; wait "$BPID" || SRC=$?
  [ "$SRC" -ne 4 ] || FOUND=1
  print_runner seed "$seed"
  halt bspid 4 "$B" "$LOGB"
  check "[p3-seed] p3a mined and quit holding a stack, and B stopped cleanly with its server.lock gone" \
    '[ "$SRC" = 0 ] && grep -q "^SCENARIO PASS capture-stall-seed-stack" "$seed" &&
     docker run --rm -m 1g --cpus 1 -v "$BVOL:/v:ro" "$IMG:head" test ! -e /v/server.lock'
  backup_run "$2" "$3" "$BVOL:/worlds/b:ro" "$bk"
  jpid=$!
  await "volume b is down" "$bk" 60 || true
  LOGB="$work/b$((++NB)).log"
  up "$B" "$BVOL" "$LOGB" 4 bspid
  HB=$NH CB=$NC
  await "capture $3 held" "$LOGB" 60 || true
  gate
  bots capture-stall-late-start-drop-pickup 2 "$B" "$HB" "$bots"
  BRC=0; wait "$BPID" || BRC=$?
  [ "$BRC" -ne 4 ] || FOUND=1
  EARLY=0; ! grep -qF "snapshotting world volume" "$bk" || EARLY=1
  JRC=0; wait "$jpid" || JRC=$?
  print_runner bots "$bots"
  sed 's/^/  run | /' "$bk"
  under=$keep
}

# $1 the run's tag; $2 its request id
p3_judge() {
  local bots="$work/$1-bots.log" bk="$work/$1-bk.log" rid=$2
  restore_set "$1" b p3a p3b
  check "[p3-bots] proof 3's bots passed behind clean holds inside the stall, and the run completed" \
    '[ "$BRC" = 0 ] && grep -q "^SCENARIO PASS capture-stall-late-start-drop-pickup" "$bots" && [ "$EARLY" = 0 ] && [ "$JRC" = 0 ]'
  check "[p3-retry] 3. the log shows B's listing differ, then the volume tarred again as held" \
    'grep -q "volume b after its tar: server.lock " "$bk" && grep -qF "volume b is held for request $rid" "$bk" && grep -q "tar of volume b, held, exited 0" "$bk"'
  check "[p3-manifest] 3. the manifest marks B held $rid" 'grep -qxF "capture_mode.b: held $rid" <<<"$MANIFEST"'
  check "[p3-stacks] 3. the restored set holds exactly one stack in p3a's file and none in p3b's" \
    'grep -qx "p3a 1" <<<"$STACKS" && grep -qx "p3b 0" <<<"$STACKS"'
}

p3_run h3 "$ROOT/deploy/backup.sh" "p3-$ID"
p3_judge h3 "p3-$ID"
gate

# A change to the volume during its tar is ignored, so B is tarred as the stopped
# volume the first listing saw, and the set holds what the bots left: p3b's stack, none
# in p3a's file, and a stopped mark in place of a held one.
sed 's|if \[ "$after" != .* \]; then|if false; then|' "$ROOT/deploy/backup.sh" >"$work/listing-ignored.sh"
printf '\n== mutant listing-ignored, against proof 3\n'
diff "$ROOT/deploy/backup.sh" "$work/listing-ignored.sh" || true
under=listing-ignored
if ! cmp -s "$ROOT/deploy/backup.sh" "$work/listing-ignored.sh"; then
  p3_run m3 "$work/listing-ignored.sh" "p3m-$ID"
  p3_judge m3 "p3m-$ID"
fi
under=""
grep '^red under listing-ignored' <<<"$RED" || true
check "mutant listing-ignored turns only [p3-retry], [p3-manifest] and [p3-stacks] red, with p3b's file holding the stack" \
  '[ "$(grep -c "^red under listing-ignored: " <<<"$RED")" = 3 ] && [ "$(grep -c "^red under listing-ignored: \[p3-\(retry\|manifest\|stacks\)\]" <<<"$RED")" = 3 ] && grep -qx "p3b 1" <<<"$STACKS"'

# ADR 015 proof 10. p10 breaks blocks in a chunk core can unload, walks out of its range
# and stays out past core's 30 s unload delay. Any other player in range would keep the
# chunk loaded and the proof would pass without testing the hold, so p10 is the only bot
# on A in that window, which the log shows. B has its own bots and no view of A's chunks.
STALL=120

# $1 a log, $2 a pattern. Prints the names with more joins than leaves in the log up to
# its first line matching the pattern.
online() {
  sed -n "1,/$2/p" "$1" | grep -oE '[^ ]+ (joined|left) the game' |
    awk '{n[$1] += ($2 == "joined") ? 1 : -1} END {for (k in n) if (n[k] > 0) print k}' || true
}

# $1 the bots' log. Starts p10 on A and returns once it waits for the stall.
p10_bots() {
  gate
  docker run --rm -m 1g --cpus 1 -v "$VOL:/d" "$IMG:head" rm -f /d/players/p10.dat
  rm -f "$work/stall" "$work/end"
  CAPTURE_STALL_FILE="$work/stall" CAPTURE_END_FILE="$work/end" bots capture-stall-chunk-out-of-range 1 "$A" "$H" "$1"
  await "CAPTURE WAIT stall" "$1" 120 || true
}

# $1 the bots' log. Lets p10 quit and sets BRC and BROKEN, the cells it broke.
p10_end() {
  touch "$work/end"
  BRC=0; wait "$BPID" || BRC=$?
  [ "$BRC" -ne 4 ] || FOUND=1
  print_runner bots "$1"
  BROKEN="$(sed -n 's/^SCENARIO PASS capture-stall-chunk-out-of-range .*CAPTURE_BROKEN=//p' "$1")"
}

# $1 a container, $2 its port, $3 a log. Joins as p10 and reads the broken cells. Sets AIRRC.
p10_air() {
  gate
  CAPTURE_BROKEN="$BROKEN" bots capture-stall-blocks-are-air 1 "$1" "$2" "$3"
  AIRRC=0; wait "$BPID" || AIRRC=$?
  [ "$AIRRC" -ne 4 ] || FOUND=1
  print_runner air "$3"
}

# The hold stands while p10 is out of range. A tool container samples p10's saved file
# on A every second for the length of the stall, and the samples up to the end of the
# window must show three mtimes, two autosaves.
p10_held() {
  local rid=p10-$ID bots="$work/p10-bots.log" bk="$work/p10-bk.log" mt="$work/p10-mtimes" jpid mpid cut times at_hold at_end
  p10_bots "$bots"
  backup_run "$ROOT/deploy/backup.sh" "$rid" "$VOL:/worlds/a:ro" "$bk"
  jpid=$!
  await "capture $rid held" "$LOG" 60 || true
  docker run --rm -m 1g --cpus 1 -e N="$STALL" -v "$VOL:/v:ro" "$IMG:head" \
    bash -c 'for ((i = 0; i < N; i++)); do echo "$(date +%s) $(stat -c %Y /v/players/p10.dat 2>/dev/null)"; sleep 1; done' >"$mt" &
  mpid=$!
  touch "$work/stall"
  await "CAPTURE WAIT end" "$bots" "$STALL" || true
  cut=$(date +%s)
  at_hold="$(online "$LOG" "capture $rid held")" at_end="$(online "$LOG" "capture $rid released")"
  p10_end "$bots"
  EARLY=0; ! grep -qF "snapshotting world volume" "$bk" || EARLY=1
  wait "$mpid" || true
  JRC=0; wait "$jpid" || JRC=$?
  sed 's/^/  run | /' "$bk"
  times="$(awk -v c="$cut" '$1 <= c && NF == 2 {print $2}' "$mt" | sort -u | tr '\n' ' ')"
  printf 'online on A at the hold: %s; at the end of the window: %s; p10 file mtimes in the window: %s\n' "$at_hold" "$at_end" "$times"
  check "[p10-alone] 10. only p10 was online on A from the hold to the end of its window, and no one else joined" \
    '[ "$at_hold" = p10 ] && [ "$at_end" = p10 ] && [ "$(sed "1,/capture $rid held/d" "$LOG" | grep -c " joined the game")" = 0 ]'
  check "[p10-saves] 10. p10's saved file on A advanced at two autosaves while it was out of range" '[ "$(wc -w <<<"$times")" -ge 3 ]'
  check "[p10-held] 10. p10 passed behind clean holds inside the stall, and the run tarred A as held after it" \
    '[ "$BRC" = 0 ] && grep -q "^SCENARIO PASS capture-stall-chunk-out-of-range" "$bots" && [ "$EARLY" = 0 ] && [ "$JRC" = 0 ] &&
     grep -qF "snapshotting world volume a, held" "$bk"'
}

# $1 a tag for the run's files; $2 the backup script to run; $3 its request id; $4 1 to
# have p10 play. Stops A cleanly inside the stall and leaves it down. Sets BRC, BROKEN and JRC.
p10_stop() {
  local bots="$work/$1-bots.log" bk="$work/$1-bk.log" jpid
  BRC=0 BROKEN=""
  [ "$4" != 1 ] || p10_bots "$bots"
  backup_run "$2" "$3" "$VOL:/worlds/a:ro" "$bk"
  jpid=$!
  # The run polls once a second, so A is stopped only after the run has seen its ack.
  await "volume a is held for request $3" "$bk" 60 || true
  if [ "$4" = 1 ]; then
    touch "$work/stall"
    await "CAPTURE WAIT end" "$bots" "$STALL" || true
    p10_end "$bots"
  fi
  halt spid 3 "$A" "$LOG"
  JRC=0; wait "$jpid" || JRC=$?
  sed 's/^/  run | /' "$bk"
}

# $1 the run's tag, $2 its request id
p10_stop_judge() {
  local bk="$work/$1-bk.log" rid=$2
  manifest_of "$1"
  check "[p10-stop-log] 7. the log shows A's ack gone at its tar and the volume called down, and the run completed" \
    'grep -qF "volume a lost its ack for request $rid before its tar" "$bk" &&
     grep -qF "volume a is down, it has no server.lock" "$bk" && [ "$JRC" = 0 ]'
  check "[p10-stop-manifest] 7. the manifest marks A stopped" 'grep -qxF "capture_mode.a: stopped" <<<"$MANIFEST"'
}

# After the release A stops cleanly and starts again, and p10 reads the cells it broke,
# which the hold kept loaded, as air.
p10_held
gate
halt spid 3 "$A" "$LOG"
LOG="$work/a$((++NA)).log"
up "$A" "$VOL" "$LOG" 3 spid
H=$NH C=$NC
p10_air "$A" "$H" "$work/p10-air.log"
check "[p10-air] 10. after the release and a clean restart of A, p10 reads the broken blocks as air" \
  '[ -n "$BROKEN" ] && [ "$AIRRC" = 0 ] && grep -q "^SCENARIO PASS capture-stall-blocks-are-air" "$work/p10-air.log"'

# Proof 1's control. main's merge-base script tars A's volume in one tar call, and the
# shim splits it: every member but p1b's file, then, once the bots have dropped and
# picked up the stack, p1b's file appended to the same archive. The read order is fixed,
# so a restored set with two stacks can come only from A's saved files being read at two
# different ticks, which is the defect the capture request exists to remove.
cat >"$work/tar" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 5 ] || [ "$1" != -C ] || [ "$2" != /worlds/a/ ] || [ "$3" != -czf ]; then exec /usr/bin/tar "$@"; fi
echo "tar shim: call on $2"
# Exit 1 is a file changing as tar read it, which a running instance's volume does.
/usr/bin/tar -C "$2" -cf /tmp/a.tar --exclude=players/p1b.dat "$5" || [ $? -eq 1 ]
touch /shim/marker
echo "tar shim: pass 1 read every member but players/p1b.dat"
timeout 300 bash -c 'until [ -e /shim/release ]; do sleep 0.2; done' || { echo "tar shim: release timed out"; exit 1; }
/usr/bin/tar -C "$2" -rvf /tmp/a.tar ./players/p1b.dat | sed 's/^/tar shim: pass 2 read /'
gzip -c /tmp/a.tar >"$4"
SH
chmod +x "$work/tar"

# True once p1a's saved file on A holds the stack.
saved() { grep -qx "p1a 1" <<<"$(stacks "$VOL" p1a)"; }

# True once both bots' saved files on A are newer than the shim's pass 1 marker.
rewritten() {
  docker run --rm -m 1g --cpus 1 -v "$VOL:/v:ro" -v "$SHIM:/s:ro" "$IMG:head" \
    bash -c '[ /v/players/p1a.dat -nt /s/marker ] && [ /v/players/p1b.dat -nt /s/marker ]'
}

# $1 tries, the rest a command, tried every 3 seconds until it holds.
retry() { local i; for ((i = 0; i < $1; i++)); do "${@:2}" && return 0; sleep 3; done; return 1; }

control() {
  local bots="$work/ctl-bots.log" bk="$work/ctl-bk.log" jpid
  printf '\n== control, deploy/backup.sh at merge base %s\n' "$(cat "${BASE_SH%/*}/sha")"
  p1_bots "$bots"
  await "CAPTURE WAIT stall" "$bots" 120 || true
  check "[ctl-pre] p1a's saved file on A holds the stack before the merge base's script runs" 'retry 20 saved'
  docker run --rm --name "$BK" -m 1g --cpus 1 --network "$NET" \
    -v "$BASE_SH:/deploy/backup.sh:ro" -v "$work/tar:/usr/local/bin/tar:ro" -v "$SHIM:/shim" \
    -v "$SETS:/backups" -v "$VOL:/worlds/a:ro" \
    -e MYSQL_HOST=db -e MYSQL_USER=root -e MYSQL_PASSWORD="$PW" -e MYSQL_DATABASE=riftal_smoke_ci \
    "$IMG:head" bash /deploy/backup.sh >"$bk" 2>&1 &
  jpid=$!
  await "tar shim: pass 1 read" "$bk" 60 || true
  touch "$work/stall"
  BRC=0; wait "$BPID" || BRC=$?
  [ "$BRC" -ne 4 ] || FOUND=1
  touch "$work/end"
  check "[ctl-rewrite] both bots' saved files on A were rewritten after pass 1 read A, before pass 2" 'retry 10 rewritten'
  docker run --rm -m 1g --cpus 1 -v "$SHIM:/s" "$IMG:head" touch /s/release
  JRC=0; wait "$jpid" || JRC=$?
  print_runner bots "$bots"
  sed 's/^/  run | /' "$bk"
  restore_set ctl a p1a p1b
  check "[ctl-bots] the control's bots passed behind clean holds" \
    '[ "$BRC" = 0 ] && grep -q "^SCENARIO PASS capture-stall-drop-pickup" "$bots"'
  check "[ctl-shim] the shim saw one tar call on A, both passes, pass 2 reading p1b's file, and the run completed" \
    '[ "$(grep -c "^tar shim: call" "$bk")" = 1 ] && grep -qx "tar shim: pass 1 read every member but players/p1b.dat" "$bk" &&
     grep -qx "tar shim: pass 2 read ./players/p1b.dat" "$bk" && ! grep -q "release timed out" "$bk" && [ "$JRC" = 0 ]'
  check "[ctl-stacks] the merge base's restored set holds two stacks, one in p1a's file and one in p1b's" \
    'grep -qx "p1a 1" <<<"$STACKS" && grep -qx "p1b 1" <<<"$STACKS"'
}

if [ "$CONTROL" = 1 ]; then
  [ "$FOUND" = 0 ] || exit 3
  [ "$FAILURES" -eq 0 ] || exit 1
  control
fi

# ADR 015 proof 6. Twenty consecutive runs against A with no stall, each started once p3a
# has joined A to mine. A's log must show each hold between p3a's join and its leave.
# A run's log names the entries of every differing listing, and the rule holds for all
# twenty (capture-cost.sh).
#
# RiftalDevBots puts every bot session at the world spawn, so a saved position cannot
# move p3a. Run n instead moves the world spawn to its own site on a grid clear of the
# spawn and of the +x lane proof 10 walks, 32 blocks apart where the bot's 8-block reach
# of one run never touches the next, and p3a joins with no saved file so the server
# places it at the new spawn. The spawn goes back to its value when the runs are done.
P6_RUNS=20 P6_RETRIED=0 P6_FAILED=0 P6_INSIDE=0 P6_BOTS=0 P6_RULE=0 P6_PLACED=0
STALL=0

cat >"$work/spawn.js" <<'JS'
const fs = require('fs')
const nbt = require('/devtools/node_modules/prismarine-nbt')
;(async () => {
  const level = nbt.simplify((await nbt.parse(fs.readFileSync('/v/worlds/world/level.dat').subarray(8), 'little')).parsed)
  console.log(`${level.SpawnX} ${level.SpawnY} ${level.SpawnZ}`)
})()
JS

read -r SPAWN_X SPAWN_Y SPAWN_Z < <(docker run --rm -m 1g --cpus 1 -v "$VOL:/v:ro" -v "$work/spawn.js:/spawn.js:ro" "$DEVTOOLS_IMAGE" \
  /devtools/node-runtime/bin/node /spawn.js) || true
[[ ${SPAWN_X:-} =~ ^-?[0-9]+$ && ${SPAWN_Y:-} =~ ^-?[0-9]+$ && ${SPAWN_Z:-} =~ ^-?[0-9]+$ ]] || { printf '::error::A level.dat holds no readable spawn\n'; exit 1; }
printf 'A spawn before proof 6: %s %s %s\n' "$SPAWN_X" "$SPAWN_Y" "$SPAWN_Z"

# $1 a console command for A. Waits for the console to answer it and prints the answer.
a_console() {
  local lines
  lines=$(wc -l <"$LOG")
  echo "$1" >&3
  timeout 5 bash -c 'until [ "$(wc -l <"$0")" -gt "$1" ]; do sleep 0.1; done' "$LOG" "$lines" || true
  sleep 0.5
  { tail -n +$((lines + 1)) "$LOG" || true; } | sed 's/^/  A | /'
}

# $1 the number of "p3a joined the game" lines A had before the run. Prints A's log from the
# login line of the run's p3a to its leave.
p6_session() {
  awk -v n="$1" '/ p3a\[.*logged in with entity id/ { login = $0 }
    / p3a joined the game/ { if (++joined == n + 1) { on = 1; print login } }
    on { print }
    on && / p3a left the game/ { exit }' "$LOG"
}

# $1 the run's number, $2 its bots' log, $3 the count p6_session takes. Prints the whole of what a
# run that did not pass left: its bots' log, the scenario's notes with the drop trace, and A's
# lines from p3a's join to its leave and the run's hold.
p6_trace() {
  local report
  printf '  == run %s did not pass: whole bots log, scenario notes, A from p3a'"'"'s join to its leave\n' "$1"
  sed 's/^/  bots-full | /' "$2"
  report="$(find "$DT/reports" -name '*-capture-stall-seed-stack.json' -newer "$work/p6-$1-mark" 2>/dev/null | head -n 1 || true)"
  if [ -n "$report" ]; then
    { docker run --rm -m 1g --cpus 1 -v "$DT/reports:/r:ro" "$DEVTOOLS_IMAGE" /devtools/node-runtime/bin/node -e \
      'for (const n of JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).notes) console.log(n)' "/r/${report##*/}" || true; } | sed 's/^/  notes | /'
  else
    printf '  notes | the scenario wrote no report\n'
  fi
  { p6_session "$3" || true; } | sed 's/^/  A | /'
  { grep -F " capture p6-$1-$ID " "$LOG" || true; } | sed 's/^/  A hold | /'
}

# $1 the run's number. Sets BRC and JRC, and counts the run in the P6 totals.
p6_run() {
  local bots="$work/p6-$1-bots.log" bk="$work/p6-$1-bk.log" seen jpid inside=0 changes entries outside empty session x z
  x=$((SPAWN_X - 64 + 32 * (($1 - 1) % 5)))
  z=$((SPAWN_Z + 32 + 32 * (($1 - 1) / 5)))
  docker run --rm -m 1g --cpus 1 -v "$VOL:/d" "$IMG:head" rm -f /d/players/p3a.dat
  a_console "setworldspawn $x $SPAWN_Y $z"
  seen=$(grep -c "p3a joined the game" "$LOG" || true)
  : >"$work/p6-$1-mark"
  BOT_TRACE_DROPS=1 bots capture-stall-seed-stack 1 "$A" "$H" "$bots"
  timeout 60 bash -c 'until [ "$(grep -c "p3a joined the game" "$0")" -gt "$1" ]; do sleep 0.2; done' "$LOG" "$seen" || true
  backup_run "$ROOT/deploy/backup.sh" "p6-$1-$ID" "$VOL:/worlds/a:ro" "$bk"
  jpid=$!
  JRC=0; wait "$jpid" || JRC=$?
  BRC=0; wait "$BPID" || BRC=$?
  [ "$BRC" -ne 4 ] || FOUND=1
  ! held_inside_session "$LOG" "p6-$1-$ID" p3a || inside=1
  read -r changes entries outside empty < <(listing_audit "$bk" a)
  print_runner bots "$bots"
  printf 'p6 run %s: run exit %s, %s differing listing(s) with %s entries (%s outside a held volume'"'"'s), hold between p3a'"'"'s join and leave: %s\n' "$1" "$JRC" "$changes" "$entries" "$outside" "$inside"
  [ "$changes" = 0 ] || grep -E ': volume a (changed during|before|after) its tar|: failed' "$bk" | sed 's/^backup [^ ]*: /  /'
  [ "$changes" = 0 ] || P6_RETRIED=$((P6_RETRIED + 1))
  [ "$JRC" = 0 ] || P6_FAILED=$((P6_FAILED + 1))
  P6_INSIDE=$((P6_INSIDE + inside))
  session="$(p6_session "$seen")"
  grep -qE "logged in with entity id [0-9]+ at \(world, $x, [0-9.-]+, $z\)" <<<"$session" && P6_PLACED=$((P6_PLACED + 1)) || true
  if [ "$BRC" = 0 ] && grep -q "^SCENARIO PASS capture-stall-seed-stack" "$bots"; then
    P6_BOTS=$((P6_BOTS + 1))
    [ "$inside" = 1 ] || p6_trace "$1" "$bots" "$seen"
  else
    p6_trace "$1" "$bots" "$seen"
  fi
  ! run_follows_listing_rule "$bk" || P6_RULE=$((P6_RULE + 1))
}

gate
for ((n = 1; n <= P6_RUNS; n++)); do p6_run "$n"; gate; done
a_console "setworldspawn $SPAWN_X $SPAWN_Y $SPAWN_Z"
printf 'proof 6: %s runs, %s retried on a differing listing, %s failed\n' "$P6_RUNS" "$P6_RETRIED" "$P6_FAILED"
printf 'backup T: volume a changed during its tar\nbackup T: volume a before its tar: players/p6.dat 9 1.5\nbackup T: complete at /backups/T\n' >"$work/p6-outside.log"
printf 'backup T: volume a changed during its tar\nbackup T: complete at /backups/T\n' >"$work/p6-empty.log"
check "[p6-bots] 6. all $P6_RUNS holds fell while p3a was online on A, each passing behind clean holds" \
  '[ "$P6_BOTS" = "$P6_RUNS" ] && [ "$P6_INSIDE" = "$P6_RUNS" ]'
check "[p6-ground] 6. p3a logged in on A at the site of each of the $P6_RUNS runs, where no earlier run mined" \
  '[ "$P6_PLACED" = "$P6_RUNS" ]'
check "[p6-rule] 6. every run completed or failed on a differing listing, and every differing listing logged entries under worlds/ or .capture/ or server.lock" \
  '[ "$P6_RULE" = "$P6_RUNS" ]'
check "[p6-red] 6. the rule refuses an entry under players/ on a held volume and a differing listing with no entry" \
  '! run_follows_listing_rule "$work/p6-outside.log" && ! run_follows_listing_rule "$work/p6-empty.log"'

# ADR 015 proof 8. A holds 500 more player files. One run with no stall gives the held
# tick and the length of a hold nothing extends. A second run takes a 120 s test stall
# and p10 roams out of range inside it, staying online past the release. `status` is
# sent every 0.5 s from the held line to the release, so the last sample inside the hold
# is the loaded chunk count and memory at release, and the second run's hold length is
# the test stall's, not a figure of the hold.
p8() {
  local rid=p8-$ID rrid=p8r-$ID bots="$work/p8-bots.log" bk="$work/p8-bk.log" rbk="$work/p8r-bk.log" jpid qpid nrc online_at roamed=0
  local files="" tick="" hold="" rfiles="" rtick="" rhold="" chunks="" mem=""
  docker run --rm -m 1g --cpus 1 -v "$VOL:/d" "$IMG:head" \
    bash -c 'for i in $(seq 1 500); do head -c 600 /dev/urandom >"/d/players/fill$i.dat"; done'
  STALL=0
  backup_run "$ROOT/deploy/backup.sh" "$rid" "$VOL:/worlds/a:ro" "$bk"
  jpid=$!
  JRC=0; wait "$jpid" || JRC=$?
  nrc=$JRC
  sed 's/^/  run | /' "$bk"
  STALL=120
  p10_bots "$bots"
  backup_run "$ROOT/deploy/backup.sh" "$rrid" "$VOL:/worlds/a:ro" "$rbk"
  jpid=$!
  await "capture $rrid held" "$LOG" 60 || true
  timeout $((STALL + 60)) bash -c 'until grep -qF "$0" "$1"; do echo status >&3; sleep 0.5; done' "capture $rrid released" "$LOG" &
  qpid=$!
  touch "$work/stall"
  await "CAPTURE WAIT end" "$bots" "$STALL" && roamed=1 || true
  wait "$qpid" || true
  online_at="$(online "$LOG" "capture $rrid released")"
  p10_end "$bots"
  JRC=0; wait "$jpid" || JRC=$?
  sed 's/^/  run | /' "$rbk"
  { grep -E "capture p8r?-$ID " "$LOG" || true; } | sed 's/^/  A | /'
  read -r files tick hold _ _ <<<"$(cost_figures "$LOG" "$rid")" || true
  read -r rfiles rtick rhold chunks mem <<<"$(cost_figures "$LOG" "$rrid")" || true
  printf 'proof 8: %s player files staged in %s ms, hold %s ms with no stall; roaming inside a %s s test stall (hold %s ms, tick %s ms, %s files): %s loaded chunks and %s MB of memory at release, online at release: %s\n' \
    "$files" "$tick" "$hold" "$STALL" "$rhold" "$rtick" "$rfiles" "$chunks" "$mem" "$online_at"
  docker run --rm -m 1g --cpus 1 -v "$VOL:/d" "$IMG:head" bash -c 'rm -f /d/players/fill*.dat'
  check "[p8-run] 8. both runs completed, and p10 roamed out of range inside the stall behind clean holds and was the only one online at the release" \
    '[ "$nrc" = 0 ] && [ "$JRC" = 0 ] && [ "$BRC" = 0 ] && [ "$roamed" = 1 ] && grep -q "^SCENARIO PASS capture-stall-chunk-out-of-range" "$bots" && [ "$online_at" = p10 ]'
  check "[p8-files] 8. each held tick staged the 500 files and the saved files already on A" '[ "${files:-0}" -ge 501 ] && [ "${rfiles:-0}" -ge 501 ]'
  check "[p8-cost] 8. the held tick's duration, the no-stall hold's length, and the loaded chunks and memory at the release of the roaming hold were read" \
    '[[ $tick =~ ^[0-9.]+$ && $hold =~ ^[0-9.]+$ && $chunks =~ ^[0-9]+$ && $mem =~ ^[0-9.]+$ ]]'
}

gate
p8
STALL=120

# Proof 10's clean stop. A is stopped cleanly inside the stall and stays down, so its ack
# is gone at the tar and the volume goes back to the wait and is called down. The set
# restores onto a fresh volume that a fresh instance boots, and p10 reads the cells it
# broke as air from it.
gate
printf '\n== proof 10, clean stop, on its own: A stays down for the whole run, so no other proof can share its stall\n'
p10_stop s "$ROOT/deploy/backup.sh" "p10s-$ID" 1
p10_stop_judge s "p10s-$ID"
check "[p10-stop-bots] 7. p10 broke blocks and passed behind clean holds before A was stopped" \
  '[ "$BRC" = 0 ] && [ -n "$BROKEN" ] && grep -q "^SCENARIO PASS capture-stall-chunk-out-of-range" "$work/s-bots.log"'
gate
KEEP=1 restore_set s a
LOGR="$work/r.log"
up "$R" "$RVOL" "$LOGR" 5 rspid
# A is down, so the restored instance takes its place in every scenario's listing.
H=$NH C=$NC
p10_air "$R" "$H" "$work/s-air.log"
check "[p10-stop-air] 7. the restored A boots on a fresh instance and p10 reads run 2's broken blocks as air" \
  '[ "$AIRRC" = 0 ] && grep -q "^SCENARIO PASS capture-stall-blocks-are-air" "$work/s-air.log"'
halt rspid 5 "$R" "$LOGR"
docker volume rm "$RVOL" >/dev/null

# The ack a held volume lost is not looked for, so A, stopped inside the stall, is tarred
# as held from a stage its stop removed: tar cannot enter it and the run fails, with no
# set, no manifest and no line for the lost ack.
sed 's|if ! listed "${first.*ack"; then|if false; then|' "$ROOT/deploy/backup.sh" >"$work/ack-ignored.sh"
printf '\n== mutant ack-ignored, against proof 10\n'
diff "$ROOT/deploy/backup.sh" "$work/ack-ignored.sh" || true
if ! cmp -s "$ROOT/deploy/backup.sh" "$work/ack-ignored.sh"; then
  gate
  LOG="$work/a$((++NA)).log"
  up "$A" "$VOL" "$LOG" 3 spid
  H=$NH C=$NC
  STALL=30
  p10_stop m "$work/ack-ignored.sh" "p10m-$ID" 0
  under=ack-ignored
  p10_stop_judge m "p10m-$ID"
  under=""
fi
grep '^red under ack-ignored' <<<"$RED" || true
check "mutant ack-ignored turns only [p10-stop-log] and [p10-stop-manifest] red" \
  '[ "$(grep -c "^red under ack-ignored: " <<<"$RED")" = 2 ] && [ "$(grep -c "^red under ack-ignored: \[p10-stop-\(log\|manifest\)\]" <<<"$RED")" = 2 ]'
