#!/usr/bin/env bash
# Proves selftest.sh leaves no container and no network behind when `timeout`
# stops it. timeout sends TERM to selftest.sh and then to its whole process
# group, and both can land separately. A run that is never interrupted never
# meets either moment, so selftest.sh cannot prove this of itself.
#
# A `docker` shim on selftest.sh's PATH makes the worst timing certain. At the
# first runner, it creates that runner's container without starting it, as a
# `docker run` killed between create and start leaves it. It then sends TERM
# to selftest.sh, and 100 ms later to the process group, the shim included, so
# the second TERM lands while selftest.sh is already handling the first.
#
# The optional argument is another copy of selftest.sh, beside its own
# README.md and fixtures/:
#   wsl -d Ubuntu-26.04 -u runner --exec bash /mnt/c/.../migrations/signal-selftest.sh
set -uo pipefail

target="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/selftest.sh}"
work="$(mktemp -d)"
pid='' net=''

# By network, not by name, because the runner has no name.
on_net() {
  docker ps -a --filter "network=$net" --format '{{.ID}} {{.Names}} {{.State}}'
}
finish() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  if [ -n "$net" ]; then
    local ids=()
    mapfile -t ids < <(on_net | cut -d' ' -f1)
    [ "${#ids[@]}" -eq 0 ] || docker rm -f -v "${ids[@]}" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
  fi
  rm -rf "$work"
}
trap finish EXIT

real="$(command -v docker)"
mkdir "$work/bin"
printf '#!/bin/sh\nreal=%q\n' "$real" >"$work/bin/docker"
cat >>"$work/bin/docker" <<'EOF'
if [ "$1" = run ] && [ "$2" = --rm ] && [ ! -e "$SIGNAL_CREATED" ]; then
  shift 2
  "$real" create "$@" >"$SIGNAL_CREATED"
  kill -TERM "$PPID"
  sleep 0.1
  kill -TERM 0
  sleep 5
fi
exec "$real" "$@"
EOF
chmod +x "$work/bin/docker"

echo "== TERM to selftest.sh, then to its process group, with a runner created and not started"
# setsid gives the run a process group of its own, as timeout does, so the
# group TERM reaches every process of the run and none of this script.
SIGNAL_CREATED="$work/created" PATH="$work/bin:$PATH" \
  setsid bash "$target" >"$work/out.log" 2>&1 &
pid=$!
# Up to 180 s to reach the first runner, then 30 s from the TERM to exit.
ticks=1800
while kill -0 "$pid" 2>/dev/null && [ "$ticks" -gt 0 ]; do
  [ -n "$net" ] || net="$(docker network ls --format '{{.Name}}' \
    | grep -m1 "^riftal_smoke_migrations_net_$pid-")"
  if [ -s "$work/created" ] && [ "$ticks" -gt 300 ]; then
    ticks=300
  fi
  ticks=$((ticks - 1))
  sleep 0.1
done
hung=0
# A cleanup that never ends leaks too: nothing else removes what it holds.
if kill -0 "$pid" 2>/dev/null; then
  hung=1
  echo "::error::selftest.sh still running 30s after TERM, or never reached a runner; killing it"
  kill -KILL -- "-$pid" 2>/dev/null
fi
wait "$pid"
rc=$?
pid=''
if [ ! -s "$work/created" ] || [ -z "$net" ]; then
  echo "::error::selftest.sh never reached a runner, so nothing was proven"
  sed 's/^/  selftest | /' "$work/out.log"
  exit 1
fi

failures=0
created="$(cut -c1-12 "$work/created")"
if [ "$hung" -eq 0 ] && [ "$rc" -eq 143 ]; then
  echo "  ok    selftest.sh exits 143 on TERM"
else
  echo "::error::selftest.sh should exit 143 on TERM, got $rc"; failures=1
fi
left="$(on_net)"
if [ -z "$left" ]; then
  echo "  ok    no container on $net is left, the created runner $created included"
else
  echo "::error::containers on $net left behind (the created runner is $created):"
  printf '%s\n' "$left" | sed 's/^/    /'
  failures=1
fi
if [ -z "$(docker network ls -q --filter "name=^${net}\$")" ]; then
  echo "  ok    network $net is removed"
else
  echo "::error::network $net left behind"; failures=1
fi
[ "$failures" -eq 0 ] || exit 1
echo "selftest.sh leaves nothing behind when timeout stops it"
