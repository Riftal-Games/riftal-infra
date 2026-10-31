#!/usr/bin/env bash
# The machine-wide rig lock the bot-proofs job shares with devtools/rig.js
# (riftal-infra#1358). One in-distro rig or bot-proofs run holds it at a time,
# because both start containers on the one docker engine of this distro. The
# lock is flock(1) on one file; the kernel frees it when its holder exits, so no
# crash leaves it stale.
#
# A flock lasts only as long as the process holding it, and each Actions step is
# its own shell. The holder is therefore a detached process that the take verb
# starts and the release verb ends, so one lock spans every step between them.
# It also ends by itself after RIG_LOCK_HOLD_SEC, so a runner that dies between
# the two cannot hold the lock for good.
#
#   bash rig-lock.sh take | rig-up-check | release

RIG_LOCK=/tmp/riftal-rig.lock
# One scenario is bounded at 1560 s, so a two-scenario rig run takes about 3120 s.
RIG_LOCK_WAIT_SEC=3600
# The bot-proofs job times out in 75 minutes, 60 of them the wait above.
RIG_LOCK_HOLD_SEC=1200
RIG_LOCK_BUSY=75

rig_lock_state_dir() {
  printf '%s\n' "${RUNNER_TEMP:?}/riftal-rig-lock"
}

# Sets seconds, the caller's local, so a refusal prints on the step's own stdout.
rig_lock_wait_sec() {
  local raw="${RIFTAL_RIG_LOCK_WAIT_SEC-}"
  if [ -z "$raw" ]; then
    seconds="$RIG_LOCK_WAIT_SEC"
  elif [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    seconds="$raw"
  else
    printf '::error::RIFTAL_RIG_LOCK_WAIT_SEC must be a whole number of seconds above 0, not "%s"\n' "$raw"
    return 1
  fi
}

# Takes the lock, waits for it up to rig_lock_wait_sec seconds, and writes the
# line a waiting rig.js prints. The holder's streams go to files: a background
# process left holding the step's own pipes would keep the step from ending.
take_rig_lock() {
  local dir seconds line pid code=0
  dir="$(rig_lock_state_dir)"
  rig_lock_wait_sec || return 1
  rm -rf "$dir"
  mkdir -p "$dir"
  line="bot-proofs run ${GITHUB_RUN_ID:?} since $(date -u +%FT%TZ)"
  if [ -e "$RIG_LOCK" ] && ! flock -n "$RIG_LOCK" true 2>/dev/null; then
    printf 'rig lock %s is held by %s; waiting up to %ss for it\n' "$RIG_LOCK" "$(head -n 1 "$RIG_LOCK" 2>/dev/null)" "$seconds"
  fi
  setsid flock -w "$seconds" -E "$RIG_LOCK_BUSY" "$RIG_LOCK" \
    sh -c 'printf "%s\n" "$1" > "$2"; echo held; exec sleep "$3"' sh "$line" "$RIG_LOCK" "$RIG_LOCK_HOLD_SEC" \
    </dev/null >"$dir/out" 2>"$dir/err" &
  pid=$!
  printf '%s\n' "$pid" >"$dir/pid"
  while ! grep -qx held "$dir/out" 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || code=$?
      rm -f "$dir/pid"
      if [ "$code" -eq "$RIG_LOCK_BUSY" ]; then
        printf '::error::the rig lock %s stayed held by %s for %ss, so bot-proofs did not start; only one in-distro rig or bot-proofs run holds it at a time\n' \
          "$RIG_LOCK" "$(head -n 1 "$RIG_LOCK" 2>/dev/null)" "$seconds"
      else
        printf '::error::taking the rig lock %s failed: flock exited %s: %s\n' "$RIG_LOCK" "$code" "$(cat "$dir/err")"
      fi
      return 1
    fi
    sleep 1
  done
  printf 'holding %s: %s\n' "$RIG_LOCK" "$line"
}

# Refuses while a rig other than this job's has running containers on the
# distro's docker. A rig left by `rig.js up` holds no lock, so the lock alone
# does not exclude it. The same names rig.js checks.
no_rig_up() {
  local out line rig
  if ! out="$(timeout 30 docker ps --filter name=riftal_smoke_ --format '{{.Names}}')"; then
    printf '::error::listing the running rigs on docker failed, so bot-proofs does not start\n'
    return 1
  fi
  while IFS= read -r line; do
    if [[ "$line" =~ ^riftal_smoke_([a-z0-9][a-z0-9-]*)(_mysql)?$ ]]; then
      rig="${BASH_REMATCH[1]}"
      printf '::error::rig %s is up on docker, and only one in-distro rig runs at a time, so bot-proofs did not start; run `node devtools/rig.js down %s --engine docker` to clear it\n' "$rig" "$rig"
      return 1
    fi
  done <<<"$out"
  printf 'no rig is up on docker\n'
}

# Ends the holder and its sleep together. Whether the lock is free afterwards is
# not asked of the file: a rig.js that was waiting may already hold it again.
release_rig_lock() {
  local dir pid i
  dir="$(rig_lock_state_dir)"
  if [ ! -f "$dir/pid" ]; then
    printf 'this job holds no rig lock\n'
    return 0
  fi
  pid="$(cat "$dir/pid")"
  kill -TERM -- "-$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill -KILL -- "-$pid" 2>/dev/null || true
  rm -f "$dir/pid"
  if kill -0 "$pid" 2>/dev/null; then
    printf '::error::the rig lock holder %s is still running after the release\n' "$pid"
    return 1
  fi
  printf 'released %s\n' "$RIG_LOCK"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1-}" in
    take) take_rig_lock ;;
    rig-up-check) no_rig_up ;;
    release) release_rig_lock ;;
    *)
      printf 'usage: rig-lock.sh take | rig-up-check | release\n' >&2
      exit 2
      ;;
  esac
fi
