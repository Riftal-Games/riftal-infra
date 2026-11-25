#!/usr/bin/env bash
# Reads the logs of one instance, one file per process lifetime, oldest first,
# and alerts when a RiftalCustody emergency repeats (riftal-pm ADR 017 item 4,
# riftal-infra#595). It reads files only, and stops, restarts or parks nothing.
#
#   custody-alert-check.sh <log> [<log> ...]
#     0  one CUSTODY OK line
#     1  one CUSTODY ALERT line per finding
#     2  usage, a log that cannot be read, a log holding more than one boot,
#        a log after the first holding none, or a first log holding none and
#        a custody emergency; never a pass
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo 'usage: custody-alert-check.sh <log> [<log> ...], one per process lifetime, oldest first' >&2
  exit 2
fi
# pmmp-core src/Server.php:813 logs this once per process, untranslated, and
# PocketMine appends server.log across restarts (MainLoggerThread.php:95). One
# file holding two boots would hide two consecutive stops as one log's stops.
banner='/INFO\]: Loading server configuration'
# Any EMERGENCY line that mentions RiftalCustody, not only the plugin's own
# prefix, so a custody line in an unexpected format still fails closed.
custody='/EMERGENCY\].*RiftalCustody'
join='concatenate log_archive/*.log oldest first ahead of server.log, then split'
first=1
for log in "$@"; do
  if [ ! -f "$log" ] || [ ! -r "$log" ]; then
    echo "custody-alert-check.sh: cannot read $log" >&2
    exit 2
  fi
  boots="$(grep -a -c -E "$banner" "$log")" || [ "$?" -eq 1 ] || {
    echo "custody-alert-check.sh: cannot read $log" >&2
    exit 2
  }
  if [ "$boots" -gt 1 ]; then
    echo "custody-alert-check.sh: $log holds $boots boots; split it at each 'Loading server configuration' line into one file per process lifetime" >&2
    exit 2
  fi
  # MainLoggerThread archives server.log by size while running, so a piece
  # without a boot line continues a lifetime from an earlier file. After the
  # first log, passing it alone would let its head piece reset the
  # consecutive-stop pairing below and hide two consecutive stops.
  if [ "$boots" -eq 0 ] && [ "$first" -eq 0 ]; then
    echo "custody-alert-check.sh: $log has no boot line ('Loading server configuration'), so it is the tail of a lifetime whose head is in an earlier piece; $join" >&2
    exit 2
  fi
  # A first log without one is either the warnings PocketMine.php logs ahead of
  # the oldest boot line or a lifetime whose head is no longer kept. With no
  # custody line it changes no finding; with one, its head is missing.
  if [ "$boots" -eq 0 ]; then
    found="$(grep -a -c -E "$custody" "$log")" || [ "$?" -eq 1 ] || {
      echo "custody-alert-check.sh: cannot read $log" >&2
      exit 2
    }
    if [ "$found" -gt 0 ]; then
      echo "custody-alert-check.sh: $log has no boot line and holds a custody emergency, so the head of its lifetime is missing; $join" >&2
      exit 2
    fi
  fi
  first=0
done

# Copied from riftal-game custody/src/RiftalGames/Custody/, with the steps from
# lib/src/RiftalGames/Lib/Player/FlushFailure.php:13-16. A custody emergency
# matching none of them alerts, so rewording a line cannot silence this check.
step='(save|read-back|file fsync|directory fsync)'
# FlushFailureResponse.php:76, instance-wide
probe_failed="^flushing .+ failed at $step and the probe failed too, so no player file can be made durable; killing the process\$"
# Shutdown.php:32-33, instance-wide. One logger call composes both forms: a
# runtime disable ("was disabled") and the last line of a refused boot
# ("refused to enable (<reason>)"), whose reason is free text.
disabled='^RiftalCustody (was disabled|refused to enable \(.+\)) while the server is running; killing the process so no world saves without it$'
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
  hits="$(grep -a -n -E "$custody" "$log")" || [ "$?" -eq 1 ] || {
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
