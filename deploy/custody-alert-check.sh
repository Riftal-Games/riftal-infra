#!/usr/bin/env bash
# Reads the logs of one instance, one file per process lifetime, oldest first,
# and alerts when a RiftalCustody emergency repeats (riftal-pm ADR 017 item 4,
# riftal-infra#595). It reads files only, and stops, restarts or parks nothing.
#
#   custody-alert-check.sh <log> [<log> ...]
#     0  one CUSTODY OK line
#     1  one CUSTODY ALERT line per finding
#     2  usage, or a log that cannot be read; never a pass
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo 'usage: custody-alert-check.sh <log> [<log> ...], one per process lifetime, oldest first' >&2
  exit 2
fi
for log in "$@"; do
  if [ ! -f "$log" ] || [ ! -r "$log" ]; then
    echo "custody-alert-check.sh: cannot read $log" >&2
    exit 2
  fi
done

# Copied from riftal-game custody/src/RiftalGames/Custody/, with the steps from
# lib/src/RiftalGames/Lib/Player/FlushFailure.php:13-16. A custody emergency
# matching none of them alerts, so rewording a line cannot silence this check.
step='(save|read-back|file fsync|directory fsync)'
# FlushFailureResponse.php:76, instance-wide
probe_failed="^flushing .+ failed at $step and the probe failed too, so no player file can be made durable; killing the process\$"
# Shutdown.php:26, instance-wide, and the last line of a refused boot
disabled='^RiftalCustody was disabled while the server is running; killing the process so no world saves without it$'
# FlushFailureResponse.php:87, one player
refused="^flushing .+ failed at $step( with nothing to probe| and the probe held); destroyed [0-9]+ item-yielding entities in .* and refusing (.+) until restart\$"
prefix='/EMERGENCY]: [RiftalCustody] '

alerts=0
alert() {
  printf 'CUSTODY ALERT: %s\n' "$1"
  alerts=$((alerts + 1))
}

stops=0
refusals=0
previous=''
declare -A named=()
declare -A times=()
for log in "$@"; do
  # Any EMERGENCY line that mentions RiftalCustody, not only the plugin's own
  # prefix, so a custody line in an unexpected format still fails closed.
  hits="$(grep -a -n -E '/EMERGENCY\].*RiftalCustody' "$log")" || [ "$?" -eq 1 ] || {
    echo "custody-alert-check.sh: cannot read $log" >&2
    exit 2
  }
  here=''
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    at="$log:${hit%%:*}"
    line="${hit#*:}"
    line="${line%$'\r'}"
    msg="${line#*"$prefix"}"
    if [ "$msg" != "$line" ] && { [[ $msg =~ $probe_failed ]] || [[ $msg =~ $disabled ]]; }; then
      here="${here:+$here, }$at"
      stops=$((stops + 1))
    elif [ "$msg" != "$line" ] && [[ $msg =~ $refused ]]; then
      name="${BASH_REMATCH[3],,}"
      named[$name]="${named[$name]:+${named[$name]}, }$at"
      times[$name]=$((${times[$name]:-0} + 1))
      refusals=$((refusals + 1))
    else
      alert "unclassified custody emergency at $at: $line"
    fi
  done <<<"$hits"
  if [ -n "$previous" ] && [ -n "$here" ]; then
    alert "instance-wide custody stop in two consecutive logs: $previous, then $here"
  fi
  previous="$here"
done

while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ "${times[$name]}" -ge 2 ]; then
    alert "player $name refused ${times[$name]} times: ${named[$name]}"
  fi
done < <(printf '%s\n' "${!named[@]}" | sort)

if [ "$alerts" -ne 0 ]; then
  exit 1
fi
printf 'CUSTODY OK: %s log(s), %s instance-wide stop(s), %s player refusal(s), none repeated\n' \
  "$#" "$stops" "$refusals"
