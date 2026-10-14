#!/usr/bin/env bash
# Self-test for write-latency-check.sh, on synthetic timings and fixture
# configs; without --probe it starts no container. Each bound has a case that must pass and one
# that must fail, so a check that passes everything fails here as surely as one
# that fails everything, and every missing or malformed input must refuse.
# LATENCY_CHECK names another copy of the script to test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${LATENCY_CHECK:-$SCRIPT_DIR/write-latency-check.sh}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

# gen <kind> <count> <ms>
gen() { awk -v k="$1" -v n="$2" -v ms="$3" 'BEGIN { for (i = 0; i < n; i++) print k, ms }'; }
# cfg <name> <line>...
cfg() {
  local name="$1"
  shift
  { echo 'plots-world: "plots"'; printf '%s\n' "$@"; } >"$DIR/$name.yml"
}
cfg k2w2 'pickup-flushes-per-tick: 2' 'tile-moves-per-tick: 2  # ADR 025'
cfg k4w1 'pickup-flushes-per-tick: 4' 'tile-moves-per-tick: 1'
cfg no-k 'tile-moves-per-tick: 2'
cfg no-w 'pickup-flushes-per-tick: 2'
cfg w-twice 'pickup-flushes-per-tick: 2' 'tile-moves-per-tick: 2' 'tile-moves-per-tick: 1'
cfg w-zero 'pickup-flushes-per-tick: 2' 'tile-moves-per-tick: 0'
cfg w-word 'pickup-flushes-per-tick: 2' 'tile-moves-per-tick: two'
cfg w-nested 'pickup-flushes-per-tick: 2' 'custody:' '  tile-moves-per-tick: 2'
printf 'pickup-flushes-per-tick: 2\r\ntile-moves-per-tick: 2\r\n' >"$DIR/crlf.yml"

{ gen player 1000 3.0; gen chunk 1000 5.0; } >"$DIR/fast"
{ gen player 1000 5.0; gen chunk 1000 13.0; } >"$DIR/slow-chunk"
{ gen player 1000 7.0; gen chunk 1000 5.0; } >"$DIR/slow-player"
{ gen player 1000 12.5; gen chunk 1000 1.0; } >"$DIR/at-budget"
# Nearest rank over 1,000 writes is the 990th: ten slow writes sit above it,
# eleven reach it.
{ gen player 990 1.0; gen player 10 20.0; gen chunk 1000 1.0; } >"$DIR/ten-slow"
{ gen player 989 1.0; gen player 11 20.0; gen chunk 1000 1.0; } >"$DIR/eleven-slow"
# Over 150 writes the rank is ceil(148.5), the 149th: two slow writes reach it.
{ gen player 148 1.0; gen player 2 20.0; gen chunk 150 1.0; } >"$DIR/two-of-150"
{ gen player 99 1.0; gen chunk 1000 1.0; } >"$DIR/few"
{ gen player 1000 1.0; gen chunk 99 1.0; } >"$DIR/few-chunk"
gen player 1000 1.0 >"$DIR/no-chunk"
{ cat "$DIR/fast"; echo 'chunk 2ms'; } >"$DIR/garbled"
sed 's/$/\r/' "$DIR/fast" >"$DIR/crlf-timings"

failures=0
ran=0
expected=24
# check <exit> <regex some output line must match> <case> <config> [timings] [flag]
check() {
  local want="$1" pattern="$2" name="$3" config="$DIR/$4.yml" input="${5:-/dev/null}" got=0 out
  ran=$((ran + 1))
  [ "$input" = /dev/null ] || input="$DIR/$input"
  out="$(bash "$CHECK" "$config" ${6:+"$6"} <"$input" 2>&1)" || got=$?
  if [ "$got" -ne "$want" ] || ! grep -q -E "$pattern" <<<"$out"; then
    printf 'FAIL %s: exit %s, wanted %s and a line matching %s\n%s\n' "$name" "$got" "$want" "$pattern" "$out"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$name"
  fi
}

check 0 '^WRITE LATENCY PASS$' "both bounds under 25 ms" k2w2 fast
check 0 'player file write p99 3\.000 ms over 1000, chunk write p99 5\.000 ms' "reports each p99" k2w2 fast
check 1 '^WRITE LATENCY FAIL: W, slower tile save p99: 2 x 13\.000' "slow chunk write fails W" k2w2 slow-chunk
check 1 'W, slower tile save p99: 1 x 7\.000 ms = 7\.000 ms, under' "slower tile save is the player write" k4w1 slow-player
check 1 '^WRITE LATENCY FAIL: K, player file write p99: 4 x 7\.000' "slow player write fails K" k4w1 slow-player
check 1 'K, player file write p99: 2 x 12\.500 ms = 25\.000 ms, not under' "exactly 25 ms fails" k2w2 at-budget
check 0 '^WRITE LATENCY PASS$' "ten slow writes sit above p99" k2w2 ten-slow
check 1 'player file write p99 20\.000' "eleven slow writes reach p99" k2w2 eleven-slow
check 0 '^WRITE LATENCY PASS$' "CRLF config and timings" crlf crlf-timings
check 2 'sets no pickup-flushes-per-tick' "refuses without K" no-k fast
check 2 'sets no tile-moves-per-tick' "refuses without W" no-w fast
check 2 'sets no tile-moves-per-tick' "refuses a nested W" w-nested fast
check 2 'more than once' "refuses W set twice" w-twice fast
check 2 'not a positive integer' "refuses W of 0" w-zero fast
check 2 'not a positive integer' "refuses W not a number" w-word fast
check 2 'timing line [0-9]+:chunk 2ms' "refuses a garbled timing" k2w2 garbled
check 1 'player file write p99 20\.000 ms over 150' "two slow writes reach p99 over 150" k2w2 two-of-150
check 2 '99 player writes, under 100' "refuses too few writes" k2w2 few
check 2 'REFUSED: 99 chunk writes, under 100' "refuses too few chunk writes" k2w2 few-chunk
check 2 'REFUSED: 0 chunk writes, under 100' "refuses no chunk writes" k2w2 no-chunk
check 2 'REFUSED: unknown argument --bound$' "refuses an unknown flag" k4w1 "" --bound
check 0 '^WRITE LATENCY: K 4 and W 1 from ' "--bounds reads K and W alone" k4w1 "" --bounds
check 2 'sets no tile-moves-per-tick' "--bounds refuses without W" no-w "" --bounds
check 2 'cannot read custody config' "refuses a missing config" absent fast

if [ "$ran" -ne "$expected" ]; then
  printf 'FAIL ran %s cases, expected %s\n' "$ran" "$expected"
  failures=$((failures + 1))
fi

# With --probe, also one short real run of write-latency-probe.sh on the pinned
# core image. Its verdict is this runner's storage, so either is accepted; a
# refusal is not.
if [ "${1:-}" = --probe ]; then
  # shellcheck source=../images/core-image.sh
  . "$SCRIPT_DIR/../images/core-image.sh"
  core_image
  # Options can point a volume at other storage, so a probe of a plain volume
  # with the same driver would measure the wrong disk. The K and W config is
  # valid, so only the options can refuse.
  opt="riftal_smoke_latency_opt_$$"
  docker volume create -o type=tmpfs -o device=tmpfs "$opt" >/dev/null
  got=0
  out="$(CORE_IMAGE="$CORE_IMAGE" CUSTODY_CONFIG="$DIR/k2w2.yml" INSTANCE_VOLUME="$opt" WRITES=100 \
    bash "$SCRIPT_DIR/write-latency-probe.sh" 2>&1)" || got=$?
  docker volume rm "$opt" >/dev/null
  if [ "$got" -ne 2 ] || ! grep -q -E "REFUSED: $opt carries driver options" <<<"$out"; then
    printf 'FAIL probe refuses a volume with driver options: exit %s, wanted 2\n%s\n' "$got" "$out"
    failures=$((failures + 1))
  else
    printf 'ok   probe refuses a volume with driver options\n'
  fi

  ref="riftal_smoke_latency_ref_$$"
  docker volume create "$ref" >/dev/null
  got=0
  out="$(CORE_IMAGE="$CORE_IMAGE" CUSTODY_CONFIG="$DIR/k2w2.yml" INSTANCE_VOLUME="$ref" WRITES=100 \
    bash "$SCRIPT_DIR/write-latency-probe.sh" 2>&1)" || got=$?
  docker volume rm "$ref" >/dev/null
  if [ "$got" -gt 1 ] || ! grep -q -E '^WRITE LATENCY: player file write p99 [0-9.]+ ms over 100, chunk write p99 [0-9.]+ ms over 100$' <<<"$out"; then
    printf 'FAIL probe run on %s: exit %s\n%s\n' "$CORE_IMAGE" "$got" "$out"
    failures=$((failures + 1))
  else
    printf 'ok   probe run on %s, exit %s\n%s\n' "$CORE_IMAGE" "$got" "$out"
  fi
fi

if [ "$failures" -ne 0 ]; then
  printf '%s write latency check case(s) failed\n' "$failures"
  exit 1
fi
echo "write latency check: all $ran cases pass"
