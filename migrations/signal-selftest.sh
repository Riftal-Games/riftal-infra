#!/usr/bin/env bash
# Proves selftest.sh's INT and TERM teardown. A run that is never interrupted
# passes with that teardown missing, so selftest.sh cannot prove it of itself.
# Runs wherever selftest.sh does:
#   wsl -d Ubuntu-26.04 -u runner --exec bash /mnt/c/.../migrations/signal-selftest.sh
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failures=0
check() {
  if [ "$1" = ok ]; then
    printf '  ok    %s\n' "$2"
  else
    printf '::error::%s\n' "$2"
    failures=$((failures + 1))
  fi
}

# A non-interactive shell starts a background job with SIGINT ignored, and bash
# cannot trap a signal it inherited as ignored. Job control leaves it at its
# default and gives each run its own process group, which the signal below
# goes to whole, as from `timeout`, a cancelled CI job or a Ctrl-C.
set -m

pid=''
suffix=''
work=''
labelled() {
  docker ps -aq --filter "label=riftal_smoke_migrations=$1"
}
# Runs after each interrupt and on any exit, so a run whose teardown is broken
# leaves nothing behind it either.
reset() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 120); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
  fi
  # By name as well as by label, so a run that dropped the label leaks nothing.
  if [ -n "$suffix" ]; then
    labelled "$suffix" | xargs -r docker rm -f -v >/dev/null 2>&1
    docker rm -f -v "riftal_smoke_migrations_$suffix" \
      "riftal_smoke_migrations_fresh_$suffix" >/dev/null 2>&1
    docker network rm "riftal_smoke_migrations_net_$suffix" >/dev/null 2>&1
  fi
  [ -z "$work" ] || rm -rf "$work"
  pid='' suffix='' work=''
}
trap reset EXIT

# The race's logs outlive it, so the next section's log marks its end. Mysql
# and at least one racing runner are up.
in_race() {
  compgen -G "$work/tmp/*/out-race-a.log" >/dev/null \
    && ! compgen -G "$work/tmp/*/out-deadlock.log" >/dev/null \
    && [ "$(labelled "$suffix" | wc -l)" -ge 2 ]
}
started() {
  [ "$(labelled "$suffix" | wc -l)" -ge 1 ]
}

# The first argument names the signal, the second the exit it must give, and
# the third a test for the moment to send it.
interrupt() {
  local sig="$1" want="$2" ready="$3" rc net left
  printf '\n== SIG%s once %s\n' "$sig" "$ready"
  if ! work="$(mktemp -d)"; then
    check fail "mktemp -d could not make a directory under ${TMPDIR:-/tmp}"
    return
  fi
  mkdir "$work/tmp"
  TMPDIR="$work/tmp" bash "$dir/selftest.sh" >"$work/out.log" 2>&1 &
  pid=$!

  # SUFFIX in selftest.sh starts with its PID, and it labels every container
  # it starts with SUFFIX.
  for _ in $(seq 1 360); do
    kill -0 "$pid" 2>/dev/null || break
    [ -n "$suffix" ] || suffix="$(docker ps -a --filter label=riftal_smoke_migrations \
      --format '{{.Label "riftal_smoke_migrations"}}' | grep -m1 "^$pid-")"
    [ -n "$suffix" ] && "$ready" && break
    sleep 0.5
  done
  if [ -z "$suffix" ] || ! "$ready" || ! kill -0 "$pid" 2>/dev/null; then
    check fail "selftest.sh never reached $ready while running"
    sed 's/^/  selftest | /' "$work/out.log"
    reset
    return
  fi

  printf '  sending SIG%s with %s labelled container(s) up\n' "$sig" "$(labelled "$suffix" | wc -l)"
  kill -"$sig" -- "-$pid"
  for _ in $(seq 1 120); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    check fail "selftest.sh still running 60s after SIG$sig"
    sed 's/^/  selftest | /' "$work/out.log"
    reset
    return
  fi
  wait "$pid"
  rc=$?

  check "$([ "$rc" -eq "$want" ] && echo ok)" "SIG$sig exits $want (got $rc)"
  left="$(labelled "$suffix" | tr '\n' ' ')"
  check "$([ -z "$left" ] && echo ok)" "no container labelled riftal_smoke_migrations=$suffix is left (got '$left')"
  net="riftal_smoke_migrations_net_$suffix"
  left="$(docker network ls -q --filter "name=^${net}\$")"
  check "$([ -z "$left" ] && echo ok)" "network $net is removed (got '$left')"
  left="$(ls -A "$work/tmp")"
  check "$([ -z "$left" ] && echo ok)" "the mktemp log directory is removed (got '$left')"
  if grep -q "interrupted by SIG$sig" "$work/out.log"; then
    check ok "selftest.sh names SIG$sig"
  else
    check fail "selftest.sh never said it was interrupted by SIG$sig"
  fi
  [ "$failures" -eq 0 ] || sed 's/^/  selftest | /' "$work/out.log"
  reset
}

# The race backgrounds two runners, so a signal there exercises the wait for
# them and the second sweep, which take a runner created after the first.
interrupt TERM 143 in_race
interrupt INT 130 started

printf '\n'
[ "$failures" -eq 0 ] || exit 1
printf 'selftest.sh tears down on SIGTERM and SIGINT\n'
