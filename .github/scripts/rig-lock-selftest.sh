#!/usr/bin/env bash
# Self-test for rig-lock.sh (riftal-infra#1358). The lock file is a temporary
# one, so the machine-wide lock is never touched, and a fake docker stands in
# for the engine. Each take and release runs in a subshell, which is how a
# step runs them: the holder is then no child of the shell that asks about it.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/rig-lock.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=17
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
holder_pid=
cleanup() {
  [ -z "$holder_pid" ] || kill -TERM -- "-$holder_pid" 2>/dev/null || true
  if [ -f "$work/state/riftal-rig-lock/pid" ]; then
    kill -TERM -- "-$(cat "$work/state/riftal-rig-lock/pid")" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
mkdir "$work/bin" "$work/state"
PATH="$work/bin:$PATH"

RIG_LOCK="$work/rig.lock"
RUNNER_TEMP="$work/state"
GITHUB_RUN_ID=4242
export RUNNER_TEMP GITHUB_RUN_ID
unset RIFTAL_RIG_LOCK_WAIT_SEC

held() { ! flock -n "$RIG_LOCK" true 2>/dev/null; }

# $1 case, $2 expected status (ok or refused), $3 text the output must hold
expect() {
  local what="$1" want="$2" text="$3" out status=0
  shift 3
  out="$("$@" 2>&1)" || status=$?
  if [ "$want" = ok ] && [ "$status" -eq 0 ] && grep -qF -- "$text" <<<"$out"; then
    pass "$what"
  elif [ "$want" = refused ] && [ "$status" -ne 0 ] && grep -qF '::error::' <<<"$out" && grep -qF -- "$text" <<<"$out"; then
    pass "$what is refused"
  else
    fail "$what: wanted $want with \"$text\", got status $status: $out"
  fi
}

( take_rig_lock >"$work/take.out" 2>&1 )
if [ $? -eq 0 ] && held; then pass "take holds the lock after its step has ended"; else fail "take should hold the lock: $(cat "$work/take.out")"; fi
if grep -qx "bot-proofs run 4242 since [0-9TZ:-]*" "$RIG_LOCK"; then pass "the lock file names the run for a waiting rig"; else fail "lock file reads: $(cat "$RIG_LOCK")"; fi

( release_rig_lock >"$work/release.out" 2>&1 )
if [ $? -eq 0 ] && ! held; then pass "release frees the lock"; else fail "release should free the lock: $(cat "$work/release.out")"; fi

( RIG_LOCK_HOLD_SEC=1 take_rig_lock >/dev/null 2>&1 )
sleep 2
expect "a holder that ended before the release" refused "was gone before the release" release_rig_lock

expect "release with nothing taken" ok "holds no rig lock" bash -c '. "$1"; RUNNER_TEMP="$2"; release_rig_lock' _ "$DIR/rig-lock.sh" "$work/empty"

( take_rig_lock >/dev/null 2>&1 )
( release_rig_lock >/dev/null 2>&1 )
( take_rig_lock >"$work/again.out" 2>&1 )
if [ $? -eq 0 ] && held; then pass "the lock can be taken again after a release"; else fail "second take: $(cat "$work/again.out")"; fi
( release_rig_lock >/dev/null 2>&1 )

# Another holder, as rig.js or an earlier bot-proofs run would be.
printf 'pid=7 verb=run rig=alpha since=2026-10-31T00:00:00Z\n' >"$RIG_LOCK"
setsid flock "$RIG_LOCK" sleep 60 </dev/null >/dev/null 2>&1 &
holder_pid=$!
sleep 1
export RIFTAL_RIG_LOCK_WAIT_SEC=2
expect "a lock held by another for the whole wait" refused "stayed held by pid=7 verb=run rig=alpha" take_rig_lock
expect "a refused take names the wait" refused "for 2s" take_rig_lock
if [ ! -f "$RUNNER_TEMP/riftal-rig-lock/pid" ]; then pass "a refused take leaves nothing to release"; else fail "a pid file is left after a refused take"; fi
expect "a refused take leaves the other holder's line" ok "pid=7" head -n 1 "$RIG_LOCK"

kill -TERM -- "-$holder_pid" 2>/dev/null
wait "$holder_pid" 2>/dev/null
holder_pid=
export RIFTAL_RIG_LOCK_WAIT_SEC=10
( take_rig_lock >"$work/after.out" 2>&1 )
if [ $? -eq 0 ] && held; then pass "a lock freed by its holder is taken"; else fail "take after the other holder ended: $(cat "$work/after.out")"; fi
( release_rig_lock >/dev/null 2>&1 )

export RIFTAL_RIG_LOCK_WAIT_SEC=soon
expect "a wait that is not a number" refused "must be a whole number" take_rig_lock
unset RIFTAL_RIG_LOCK_WAIT_SEC

fake() {
  { printf '#!/bin/sh\n'; cat; } >"$work/bin/docker"
  chmod +x "$work/bin/docker"
}
fake <<'EOF'
exit 0
EOF
expect "no containers" ok "no rig is up" no_rig_up
fake <<'EOF'
printf 'riftal_smoke_alpha_mysql\nriftal_smoke_alpha\n'
EOF
expect "a running rig" refused 'node devtools/rig.js down alpha --engine docker' no_rig_up
fake <<'EOF'
printf 'riftal_smoke_beta-2_mysql\n'
EOF
expect "a rig with only its database up" refused 'rig beta-2 is up' no_rig_up
fake <<'EOF'
printf 'riftal_smoke_sweep_own\nriftal_smoke_level_hub\n'
EOF
expect "containers whose names are not a rig's" ok "no rig is up" no_rig_up
fake <<'EOF'
exit 1
EOF
expect "a docker that cannot list" refused "listing the running rigs" no_rig_up

if [ "$((PASSES + FAILURES))" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '::error::ran %s assertions, expected %s\n' "$((PASSES + FAILURES))" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '::error::%s of %s assertions failed\n' "$FAILURES" "$EXPECTED_ASSERTIONS"
  exit 1
fi
printf 'all %s assertions passed\n' "$PASSES"
