#!/usr/bin/env bash
# Usage: write-latency-check.sh <custody config.yml> [--bounds]
#
# Reads write-latency-probe.php's timing lines on stdin and holds their p99s to
# the bounds of the riftal-pm workspace's ADR 017 P11 and ADR 025 P7: the
# player file write's p99 times K under 25 ms, and the slower tile save's p99
# times W under 25 ms. A deposit's save is the player file write and a
# withdrawal's is the chunk write (ADR 025 items 4 and 5), so the slower tile
# save is the slower of the two.
#
# K and W come from the RiftalCustody config.yml the instance boots with,
# never from a copy here; --bounds reads and prints only them. Exit 0 pass,
# 1 fail, 2 refused, on stderr: a missing or malformed K or W or timing line,
# or under MIN_SAMPLES writes of either kind.
set -euo pipefail

BUDGET_MS=25
MIN_SAMPLES="${MIN_SAMPLES:-100}"

refuse() {
  printf 'WRITE LATENCY REFUSED: %s\n' "$1" >&2
  exit 2
}

[ "$#" -ge 1 ] || refuse "usage: write-latency-check.sh <custody config.yml> [--bounds]"
config="$1"
[ -r "$config" ] || refuse "cannot read custody config $config"

# Prints the one top-level plain positive integer set for $1, or refuses.
bound() {
  local key="$1" values
  values="$(tr -d '\r' <"$config" | sed -n -E "s/^$key:[[:space:]]*([^#]*[^#[:space:]])?[[:space:]]*(#.*)?\$/\1/p")"
  [ -n "$values" ] || refuse "$config sets no $key"
  [ "$(printf '%s\n' "$values" | wc -l)" -eq 1 ] || refuse "$config sets $key more than once"
  [[ "$values" =~ ^[1-9][0-9]*$ ]] || refuse "$config sets $key to \"$values\", not a positive integer"
  printf '%s' "$values"
}
k="$(bound pickup-flushes-per-tick)"
w="$(bound tile-moves-per-tick)"
printf 'WRITE LATENCY: K %s and W %s from %s\n' "$k" "$w" "$config"
[ "${2:-}" = "--bounds" ] && exit 0

timings="$(mktemp)"
trap 'rm -f "$timings"' EXIT
tr -d '\r' >"$timings"
bad="$(grep -n -v -E '^(player|chunk) [0-9]+(\.[0-9]+)?$' "$timings" | head -n 1 || true)"
[ -z "$bad" ] || refuse "timing line $bad is not \"player <ms>\" or \"chunk <ms>\""

# Nearest-rank p99 of one kind's timings, as "<count> <p99>".
p99() {
  awk -v kind="$1" '$1 == kind { print $2 }' "$timings" | sort -g \
    | awk '{ v[NR] = $1 } END { r = int(NR * 0.99); if (r < NR * 0.99) r++; printf "%d %.3f\n", NR, (NR ? v[r] : 0) }'
}
read -r player_n player_p99 < <(p99 player)
read -r chunk_n chunk_p99 < <(p99 chunk)
[ "$player_n" -ge "$MIN_SAMPLES" ] || refuse "$player_n player writes, under $MIN_SAMPLES"
[ "$chunk_n" -ge "$MIN_SAMPLES" ] || refuse "$chunk_n chunk writes, under $MIN_SAMPLES"
printf 'WRITE LATENCY: player file write p99 %s ms over %s, chunk write p99 %s ms over %s\n' \
  "$player_p99" "$player_n" "$chunk_p99" "$chunk_n"

verdict=0
# judge <label> <bound> <p99>
judge() {
  local product
  product="$(awk -v b="$2" -v p="$3" 'BEGIN { printf "%.3f", b * p }')"
  if awk -v x="$product" -v max="$BUDGET_MS" 'BEGIN { exit !(x < max) }'; then
    printf 'WRITE LATENCY: %s %s x %s ms = %s ms, under %s ms\n' "$1" "$2" "$3" "$product" "$BUDGET_MS"
  else
    printf 'WRITE LATENCY FAIL: %s %s x %s ms = %s ms, not under %s ms\n' "$1" "$2" "$3" "$product" "$BUDGET_MS"
    verdict=1
  fi
}
judge "K, player file write p99:" "$k" "$player_p99"
judge "W, slower tile save p99:" "$w" "$(awk -v a="$player_p99" -v b="$chunk_p99" 'BEGIN { printf "%.3f", (a > b ? a : b) }')"
if [ "$verdict" -eq 0 ]; then
  echo "WRITE LATENCY PASS"
else
  echo "WRITE LATENCY FAIL: lower K or W in tuning before opening"
fi
exit "$verdict"
