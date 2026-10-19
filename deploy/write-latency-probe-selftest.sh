#!/usr/bin/env bash
# Self-test for write-latency-probe.sh. Without --probe it runs the probe
# against a stub docker that records its arguments, so it needs no daemon:
# the probe volume must take the instance volume's driver and be the one
# mounted at the path the probe writes to, or a probe of a networked volume
# would time the host's local disk. With --probe it also runs the probe for
# real on the pinned core image.
# LATENCY_PROBE names another copy of the script to test; it must sit beside a
# write-latency-check.sh and a write-latency-probe.php.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${LATENCY_PROBE:-$SCRIPT_DIR/write-latency-probe.sh}"
DIR="$(mktemp -d)"
opt="riftal_smoke_latency_opt_$$"
ref="riftal_smoke_latency_ref_$$"
cleanup() {
  if [ "${1:-}" = --probe ]; then
    docker volume rm -f "$opt" "$ref" >/dev/null 2>&1 || true
  fi
  rm -rf "$DIR"
}
trap 'cleanup "${PROBE_RUN:-}"' EXIT

printf 'pickup-flushes-per-tick: 2\ntile-moves-per-tick: 2\n' >"$DIR/k2w2.yml"

cat >"$DIR/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1" in
  volume)
    case "$2" in
      inspect)
        if [ "$4" = '{{.Driver}}' ]; then echo riftal-fake; else echo 0; fi
        ;;
      create) exit "${STUB_CREATE_EXIT:-0}" ;;
      rm) ;;
      *) exit 99 ;;
    esac
    ;;
  run)
    awk 'BEGIN { for (i = 0; i < 100; i++) print "player 1.0"; for (i = 0; i < 100; i++) print "chunk 1.0" }'
    ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$DIR/docker"

failures=0
fail() {
  printf 'FAIL %s\n%s\n--- docker calls ---\n%s\n' "$1" "$2" "$(cat "$DIR/log" 2>/dev/null)"
  failures=$((failures + 1))
}

# stub <create exit>: runs the probe on the stub, setting out and got.
stub() {
  : >"$DIR/log"
  got=0
  out="$(DOCKER="$DIR/docker" STUB_LOG="$DIR/log" STUB_CREATE_EXIT="$1" \
    CORE_IMAGE=riftal-stub:1 CUSTODY_CONFIG="$DIR/k2w2.yml" INSTANCE_VOLUME=instance-data WRITES=100 \
    bash "$PROBE" 2>&1)" || got=$?
}

stub 0
created="$(sed -n -E 's/^volume create --driver riftal-fake (riftal_smoke_latency_[0-9_]+)$/\1/p' "$DIR/log")"
runs="$(grep -c '^run ' "$DIR/log" || true)"
if [ "$got" -ne 0 ] || ! grep -q '^WRITE LATENCY PASS$' <<<"$out"; then
  fail "stub probe passes: exit $got, wanted 0 and WRITE LATENCY PASS" "$out"
elif [ -z "$created" ]; then
  fail "probe volume takes the instance volume's driver: no volume create --driver riftal-fake <probe volume>" "$out"
elif [ "$runs" -ne 1 ] || ! grep -q -E -- "^run .* -v $created:/data .* /probe\.php /data 100\$" "$DIR/log"; then
  fail "probe runs once with $created mounted at /data and writes to /data" "$out"
elif ! grep -q -x "volume rm $created" "$DIR/log"; then
  fail "probe removes $created" "$out"
else
  printf 'ok   probe volume takes driver riftal-fake, is mounted at /data and removed\n'
fi

stub 1
runs="$(grep -c '^run ' "$DIR/log" || true)"
if [ "$got" -ne 2 ] || ! grep -q 'REFUSED: cannot create a riftal-fake volume riftal_smoke_latency_' <<<"$out" || [ "$runs" -ne 0 ]; then
  fail "failed volume create refuses before any run: exit $got, wanted 2, $runs run(s)" "$out"
else
  printf 'ok   failed volume create refuses before any run\n'
fi

if [ "${1:-}" = --probe ]; then
  PROBE_RUN=--probe
  # shellcheck source=SCRIPTDIR/../images/core-image.sh
  . "$SCRIPT_DIR/../images/core-image.sh"
  core_image
  : >"$DIR/log"

  # Options can point a volume at other storage, so a probe of a plain volume
  # with the same driver would measure the wrong disk. The K and W config is
  # valid, so only the options can refuse.
  docker volume create -o type=tmpfs -o device=tmpfs "$opt" >/dev/null
  got=0
  out="$(CORE_IMAGE="$CORE_IMAGE" CUSTODY_CONFIG="$DIR/k2w2.yml" INSTANCE_VOLUME="$opt" WRITES=100 \
    bash "$PROBE" 2>&1)" || got=$?
  if [ "$got" -ne 2 ] || ! grep -q -E "REFUSED: $opt carries driver options" <<<"$out"; then
    fail "probe refuses a volume with driver options: exit $got, wanted 2" "$out"
  else
    printf 'ok   probe refuses a volume with driver options\n'
  fi

  # Its verdict is this host's storage, so either is accepted; a refusal is not.
  docker volume create "$ref" >/dev/null
  got=0
  out="$(CORE_IMAGE="$CORE_IMAGE" CUSTODY_CONFIG="$DIR/k2w2.yml" INSTANCE_VOLUME="$ref" WRITES=100 \
    bash "$PROBE" 2>&1)" || got=$?
  if [ "$got" -gt 1 ] || ! grep -q -E '^WRITE LATENCY: player file write p99 [0-9.]+ ms over 100, chunk write p99 [0-9.]+ ms over 100$' <<<"$out"; then
    fail "probe run on $CORE_IMAGE: exit $got" "$out"
  else
    printf 'ok   probe run on %s, exit %s\n%s\n' "$CORE_IMAGE" "$got" "$out"
  fi
fi

if [ "$failures" -ne 0 ]; then
  printf '%s write latency probe case(s) failed\n' "$failures"
  exit 1
fi
echo "write latency probe: all cases pass"
