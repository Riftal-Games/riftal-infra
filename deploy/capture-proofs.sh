#!/usr/bin/env bash
# ADR 015 proofs 3, 4 and 5, every part without bots (riftal-pm
# docs/decisions/015-backup-captures-each-instance-at-one-held-tick.md,
# riftal-infra#1076). Runs only as a CI step on the self-hosted runner: it boots
# the pinned core from ../images/core-image.sha with RiftalCapture and runs
# backup.sh in the image built from ../images/backup against one instance's
# volume, mounted at /worlds/b. Every proof is asserted from backup.sh's log,
# its manifest and tar, and the server's own log.
#
# Each mutant at the end is a one-line sed of backup.sh. The proof it targets
# is run again against it, and the tagged assertion must go red.
#
# backup.sh calls tar by name, so a shim mounted first on PATH holds tar's
# first call at a gate, before or after running the image's own tar, until
# this script lets it through. A proof acts on the instance at that gate.
#
# Every container, volume, network and image here is riftal_smoke_cproofs_*,
# suffixed with the run id and pid alone, and is removed by the EXIT trap. The
# instance publishes 19132/udp on 127.0.0.1 only. It stops with `stop` on
# stdin, except where proof 3 kills it.
#
# Each condition reaches check single-quoted and is expanded by its eval, so
# the variables it names are read there.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
trap '' PIPE

[ "${GITHUB_ACTIONS:-}" = true ] || { printf '::error::this runs only in GitHub Actions\n'; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../images/core-image.sh
. "$DIR/../images/core-image.sh"
core_image || { printf 'the pinned core image is missing, so nothing was booted\n'; exit 1; }

RUN="${GITHUB_RUN_ID:-0}_$$"
NET=riftal_smoke_cproofs_net_$RUN
DB=riftal_smoke_cproofs_db_$RUN
SRV=riftal_smoke_cproofs_srv_$RUN
JOB=riftal_smoke_cproofs_job_$RUN
VOL=riftal_smoke_cproofs_vol_$RUN
CAP=riftal_smoke_cproofs_cap_$RUN
SETS=riftal_smoke_cproofs_sets_$RUN
RST=riftal_smoke_cproofs_rst_$RUN
IMG=riftal_smoke_cproofs:$RUN
EXPECTED_ASSERTIONS=23

work="$(mktemp -d)"
WITH="$work/with"
WITHOUT="$work/without"
spid=""
jpid=""
boots=0
under=""
RED=""
PASSES=0
FAILURES=0

# $1 seconds: true once the instance's process has exited within them.
gone() {
  local i
  for ((i = 0; i < $1 * 5; i++)); do
    kill -0 "$spid" 2>/dev/null || break
    sleep 0.2
  done
  ! kill -0 "$spid" 2>/dev/null || return 1
  exec 3>&-
  wait "$spid" || true
  spid=""
}

halt() {
  [ -n "$spid" ] || return 0
  echo stop >&3 || true
  gone 60 || { docker stop -t 30 "$SRV" >/dev/null 2>&1 || true; gone 40; }
}

kill_srv() { docker kill "$SRV" >/dev/null && gone 30; }

cleanup() {
  [ -z "$jpid" ] || { docker kill "$JOB" >/dev/null 2>&1; wait "$jpid"; } || true
  halt || true
  docker rm -f -v "$DB" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm "$VOL" "$CAP" "$SETS" "$RST" >/dev/null 2>&1 || true
  docker image rm "$IMG" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# $1 what is claimed; $2 a condition, evaluated. Under a mutant, a failure is
# collected in RED instead of counted.
check() {
  if eval "$2"; then
    [ -n "$under" ] || { printf 'ok %s\n' "$1"; PASSES=$((PASSES + 1)); }
  elif [ -n "$under" ]; then
    RED+="red under $under: $1"$'\n'
  else
    printf 'FAIL %s\n' "$1"
    FAILURES=$((FAILURES + 1))
    [ -z "${slog:-}" ] || tail -n 40 "$slog"
  fi
}

# $1 a literal string; $2 a file; $3 seconds to wait for the string in it
await() {
  local deadline=$(($(date +%s) + $3))
  until grep -qF -- "$1" "$2" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

# $1 the plugins folder; $2 the volume, VOL when empty; $3 nowait to return before Done
boot() {
  boots=$((boots + 1))
  slog="$work/srv$boots.log"
  mkfifo "$work/in$boots"
  docker run --rm -i --name "$SRV" -m 2g --cpus 2 -p 127.0.0.1::19132/udp \
    -v "${2:-$VOL}:/data" -v "$1:/plugins:ro" -v "$CAP:/capture:ro" \
    -e "POCKETMINE_ARGS=--level-type=flat --xbox-auth=false --auto-report.enabled=0" \
    "$CORE_IMAGE" start-pocketmine <"$work/in$boots" >"$slog" 2>&1 &
  spid=$!
  exec 3>"$work/in$boots"
  [ "${3:-}" = nowait ] || await 'Done (' "$slog" 120 || { cat "$slog"; return 1; }
}

# Every proof starts with no instance, no live request, no raised fence and no
# lock left by a killed run.
begin() {
  halt
  docker exec "$DB" mysql -uroot -priftal_smoke_only riftal_smoke_cproofs \
    -e 'UPDATE capture_fence SET request_id = NULL, raised_until = NULL WHERE id = 1'
  docker run --rm -m 1g --cpus 1 -v "$CAP:/c" -v "$SETS:/s" "$IMG" rm -rf /c/request /s/.lock
  boot "$@"
}

# $1 the script; $2 the request id; $3 where the shim holds tar, before, after
# or nowhere when empty. HOLD sets the lease, 30 seconds unless given; any
# further argument goes to docker run.
job_bg() {
  local script="$1" id="$2" gate="$3"
  shift 3
  rm -rf "$work/gate" && mkdir "$work/gate"
  blog="$work/job-$id.log"
  docker run --rm --name "$JOB" -m 1g --cpus 1 --network "$NET" \
    -v "$script:/deploy/backup.sh:ro" -v "$work/tar:/usr/local/bin/tar:ro" -v "$work/gate:/gate" \
    -v "$SETS:/backups" -v "$CAP:/capture" -v "$VOL:/worlds/b:ro" \
    -e MYSQL_HOST=db -e MYSQL_USER=root -e MYSQL_PASSWORD=riftal_smoke_only -e MYSQL_DATABASE=riftal_smoke_cproofs \
    -e CAPTURE_TEST_REQUEST_ID="$id" -e GATE="$gate" -e CAPTURE_HOLD_MAX_SECONDS="${HOLD:-30}" "$@" \
    "$IMG" bash /deploy/backup.sh >"$blog" 2>&1 &
  jpid=$!
}

# Lets tar through the gate, then sets jrc to the run's exit status.
job_end() {
  touch "$work/gate/go"
  jrc=0
  wait "$jpid" || jrc=$?
  jpid=""
  sed 's/^/  | /' "$blog"
}

job() { job_bg "$@"; job_end; }

in_sets() { docker run --rm -m 1g --cpus 1 -v "$SETS:/b:ro" "$IMG" bash -c "$1"; }

set_of() { sed -n 's|.*complete at /backups/||p' "$blog"; }

# $1 a whole manifest line: true when the last run's set holds it.
manifest_has() {
  [ -n "$(set_of)" ] && grep -qxF -- "$1" <<<"$(in_sets "cat /b/$(set_of)/manifest.txt")"
}

lock_probe() {
  docker run --rm -m 1g --cpus 1 -v "$VOL:/w:ro" "$IMG" \
    bash -c 'exec 9</w/server.lock && if flock -xn 9; then echo free; else echo held; fi'
}

# Writes random bytes to players/m.dat on the running instance and prints their sha256.
mark() {
  docker exec "$SRV" sh -c 'mkdir -p /data/players && head -c 512 /dev/urandom >/data/players/m.dat &&
    sha256sum /data/players/m.dat' | cut -d' ' -f1
}

# $1 a sha256: true when the last set's tar, extracted onto a fresh volume,
# boots and holds players/m.dat with that hash.
restores() {
  local ok=1
  docker volume create "$RST" >/dev/null
  if ! docker run --rm -m 1g --cpus 1 -v "$SETS:/b:ro" -v "$RST:/r" "$IMG" \
    bash -c "tar -xzf /b/$(set_of)/worlds/b.tar.gz -C /r && chown -R 1000:1000 /r" \
    || ! boot "$WITHOUT" "$RST" \
    || [ "$(docker exec "$SRV" sha256sum /data/players/m.dat | cut -d' ' -f1)" != "$1" ]; then
    ok=0
  fi
  halt
  docker volume rm "$RST" >/dev/null
  [ "$ok" = 1 ]
}

# Proof 3: a cleanly stopped and a killed instance are each tarred as they lie,
# marked stopped, and restore to a volume that boots with the player file
# written last. flock -xn in the backup image tells the two lock states apart.
p3_down() {
  local sum
  begin "$WITH"
  check "3. in the backup image, flock -xn on the read-only mount fails against a running core" \
    '[ "$(lock_probe)" = held ]'
  sum="$(mark)"
  halt
  job "$1" "$2-clean" ""
  check "3. a cleanly stopped instance, its server.lock absent, is tarred as stopped" \
    '[ "$jrc" = 0 ] && grep -qF "volume b is down, it has no server.lock" "$blog" && manifest_has "capture_mode.b: stopped"'
  check "3. that set restores to a fresh volume that boots with the player file written last" 'restores "$sum"'
  begin "$WITH"
  sum="$(mark)"
  kill_srv
  check "3. in the backup image, flock -xn on the read-only mount succeeds on a killed core's free lock" \
    '[ "$(lock_probe)" = free ]'
  job "$1" "$2-killed" ""
  check "3. a killed instance is tarred as stopped" \
    '[ "$jrc" = 0 ] && grep -qF "volume b is down, its server.lock is free" "$blog" && manifest_has "capture_mode.b: stopped"'
  check "3. the killed instance's set restores to a fresh volume that boots with the player file written last" \
    'restores "$sum"'
}

# Proof 3: an instance started on its cleanly stopped volume after the run
# called it down, with $3 the gate, makes the listing differ, and the volume
# is tarred again as held.
p3_start() {
  local id="$2-$3"
  begin "$WITH" && halt
  job_bg "$1" "$id" "$3"
  await 'tar shim: at the gate' "$blog" 60
  boot "$WITH" && await "capture $id held" "$slog" 30
  job_end
  check "[start-$3] 3. a start $3 tar read the cleanly stopped volume makes its listing differ, and it is tarred again as held" \
    '[ "$jrc" = 0 ] && grep -qF "volume b changed during its tar" "$blog" && manifest_has "capture_mode.b: held $id"'
  halt
}

p3_before() { p3_start "$1" "$2" before; }
p3_during() { p3_start "$1" "$2" after; }

# Proof 3: a start after the run called a killed volume down blocks in core's
# flock until the volume is verified, then exits at core's lock check.
p3_killed_start() {
  local id="$2-kstart"
  begin "$WITH" && kill_srv
  job_bg "$1" "$id" before
  await 'tar shim: at the gate' "$blog" 60
  boot "$WITH" "" nowait
  check "[blocked] 3. a start after the run called its killed volume down reaches no Done while the run holds the lock" \
    '! await "Done (" "$slog" 15'
  job_end
  check "3. once the run has verified that volume, as stopped, the start exits at core's lock check" \
    '[ "$jrc" = 0 ] && manifest_has "capture_mode.b: stopped" && await "is already using this folder" "$slog" 30'
  gone 30 || halt
  check "3. started again after the run, as its restart policy does, the instance boots the volume" 'boot "$WITH"'
  halt
}

# Proof 4: an instance running without RiftalCapture fails the run within the
# ack timeout, the log names the volume, and no set is written.
p4() {
  local id="$2-p4" before took
  begin "$WITHOUT"
  before="$(in_sets 'ls -A /b')"
  took=$(date +%s)
  job "$1" "$id" "" -e CAPTURE_ACK_TIMEOUT_SECONDS=10
  took=$(($(date +%s) - took))
  check "[ack-timeout] 4. an instance without RiftalCapture fails the run within the 10s ack timeout, naming volume b" \
    '[ "$jrc" != 0 ] && [ "$took" -lt 40 ] && grep -qF "volume b: after 10s its instance is running and has not acked" "$blog"'
  check "4. that run writes no set" '[ "$(in_sets "ls -A /b")" = "$before" ]'
  halt
}

# Proof 5: an operator's save-off survives a full run, whose end releases the hold.
p5_operator() {
  local id="$2-op"
  begin "$WITH"
  echo save-off >&3
  await 'Turned off world auto-saving' "$slog" 10 || true
  job "$1" "$id" ""
  check "[op] 5. an operator's earlier save-off survives a full run: released within 5s of its end, autosave off" \
    '[ "$jrc" = 0 ] && await "capture $id released, autosave off" "$slog" 5'
  halt
}

# Proof 5: an acked instance restarted during its tar makes the run wait for
# the new ack and tar the new stage, which alone holds players/p5.dat.
p5_restart() {
  local id="$2-restart"
  begin "$WITH"
  job_bg "$1" "$id" after
  await 'tar shim: at the gate' "$blog" 60
  docker exec "$SRV" sh -c 'mkdir -p /data/players && head -c 64 /dev/urandom >/data/players/p5.dat'
  halt
  boot "$WITH" && await "capture $id held" "$slog" 30
  job_end
  check "[restart] 5. an instance restarted during its tar is tarred again, held, from the stage of its new ack" \
    '[ "$jrc" = 0 ] && grep -qF "volume b changed during its tar" "$blog" && manifest_has "capture_mode.b: held $id" &&
     grep -qx players/p5.dat <<<"$(in_sets "tar -tzf /b/$(set_of)/worlds/b.tar.gz")"'
  halt
}

# Proof 5: with the run killed during its hold, the lease alone ends the hold.
p5_lease() {
  local id="$2-lease"
  begin "$WITH"
  HOLD=12 job_bg "$1" "$id" before
  await 'tar shim: at the gate' "$blog" 60
  docker kill "$JOB" >/dev/null
  job_end
  check "[lease] 5. a run killed during its hold leaves it to the 12s lease, which ends it with autosave on" \
    'grep -qF "capture $id held" "$slog" && await "capture $id released, autosave on" "$slog" 15'
  check "5. after the lease the volume's .capture is empty" '[ -z "$(docker exec "$SRV" ls -A /data/.capture)" ]'
  halt
}

# $1 the mutant's name; $2 the sed that makes it from backup.sh; $3 the proof
# run against it; $4 the tag of the assertion it must turn red.
mutant() {
  local script="$work/$1.sh" want="$4" name="$1"
  sed "$2" "$DIR/backup.sh" >"$script"
  printf '\n== mutant %s, against %s\n' "$1" "$3"
  diff "$DIR/backup.sh" "$script" || true
  RED=""
  under="$1"
  if ! cmp -s "$DIR/backup.sh" "$script"; then
    "$3" "$script" "$1" || true
  fi
  under=""
  printf '%s' "$RED"
  check "mutant $1 turns $want red, its run having taken the lock and written its request" \
    '[[ $RED == *"$want"* ]] && grep -qF "requesting a held capture $name-" "$blog"'
}

mkdir "$WITH" "$WITHOUT"
cp "$DIR/../images/plugins/RiftalCapture.php" "$WITH/"
cat >"$work/tar" <<'EOF'
#!/bin/bash
rc=0
[ "${GATE:-}" != after ] || /usr/bin/tar "$@" || rc=$?
if [ -n "${GATE:-}" ] && mkdir /gate/passed 2>/dev/null; then
  echo "tar shim: at the gate" >&2
  until [ -e /gate/go ]; do sleep 0.2; done
fi
[ "${GATE:-}" != after ] || exit "$rc"
exec /usr/bin/tar "$@"
EOF
chmod -R a+rX "$work"
chmod 755 "$work/tar"

docker build -q -t "$IMG" "$DIR/../images/backup" >/dev/null
docker network create "$NET" >/dev/null
for vol in "$VOL" "$CAP" "$SETS"; do
  docker volume create "$vol" >/dev/null
done
docker run -d --rm --name "$DB" -m 1g --cpus 1 --network "$NET" --network-alias db \
  -e MYSQL_ROOT_PASSWORD=riftal_smoke_only -e MYSQL_DATABASE=riftal_smoke_cproofs mysql:8 >/dev/null
for _ in $(seq 1 90); do
  docker exec "$DB" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1 && break
  sleep 1
done
docker exec -i "$DB" mysql -uroot -priftal_smoke_only riftal_smoke_cproofs <"$DIR/fence-fixture.sql"

for proof in p3_down p3_before p3_during p3_killed_start p4 p5_operator p5_restart p5_lease; do
  printf '\n== %s against backup.sh\n' "$proof"
  "$proof" "$DIR/backup.sh" head || true
done

mutant lock-blind 's/if flock -xn "$fd"; then/if true; then/' p4 '[ack-timeout]'
mutant lock-dropped 's/lock_fd\[$name\]="$fd"/exec {fd}<\&-/' p3_killed_start '[blocked]'
mutant listing-ignored 's/if \[ "$after" != "${first\[$name\]}" \]; then/if false; then/' p3_during '[start-after]'
mutant listing-ignored 's/if \[ "$after" != "${first\[$name\]}" \]; then/if false; then/' p5_restart '[restart]'
mutant request-kept 's|^    rm -f "$CAPTURE_DIR/request"$|    :|' p5_operator '[op]'
mutant lease-unbounded 's/+ CAPTURE_HOLD_MAX_SECONDS ))/+ CAPTURE_HOLD_MAX_SECONDS * 100 ))/' p5_lease '[lease]'

ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ] || [ "$FAILURES" -ne 0 ]; then
  printf '::error::%s of %s assertions ran and %s failed\n' "$ran" "$EXPECTED_ASSERTIONS" "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed on the real core: ADR 015 proofs 3, 4 and 5 without bots, each red under its mutant of backup.sh.\n' "$PASSES"
