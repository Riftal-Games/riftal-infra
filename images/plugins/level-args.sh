#!/bin/bash
# Sourced, never run. The rule one instance definition's RIFTAL_LEVEL_ZONES and
# POCKETMINE_ARGS must meet, one copy for deploy/instance-levels-check.sh in CI
# and for the release image's start command (ADR 043 item 3), so the file CI read
# is the rule the boot applies. Each *_findings function takes its values as
# arguments, prints one finding per line and returns 1 when it printed any.
#
# A value is non-empty and holds letters, digits, space and _ . , : = / @ + -
# only. A zone matches [a-z0-9_]+ and none repeats. POCKETMINE_ARGS is split on
# whitespace as start-instance.sh splits it, every token is one long option,
# --name or --name=value, because core's getopt stops at the first token that is
# not one, at a lone - and at --, and reads nothing after. It holds no --worlds
# token, exactly one --level-name=<zone> and that zone is listed. Core reads
# --level-name as an optional-value option, so a bare one is no name and boot
# would generate "world".

LEVEL_VALUE_RE='^[A-Za-z0-9 _.,:=/@+-]+$'
LEVEL_OPTION_RE='^--[A-Za-z0-9][A-Za-z0-9._-]*(=.*)?$'
LEVEL_ZONE_RE='^[a-z0-9_]+$'

# $1 RIFTAL_LEVEL_ZONES, unset or empty when missing.
level_zones_findings() {
  local value="${1-}" zone zones found=0
  local -A seen=()
  if [ -z "$value" ]; then
    echo "RIFTAL_LEVEL_ZONES is unset or empty"
    return 1
  fi
  if ! [[ $value =~ $LEVEL_VALUE_RE ]]; then
    echo "RIFTAL_LEVEL_ZONES holds a character outside letters, digits, space and _ . , : = / @ + -"
    return 1
  fi
  read -ra zones <<<"$value"
  if [ "${#zones[@]}" -eq 0 ]; then
    echo "RIFTAL_LEVEL_ZONES lists no zone"
    return 1
  fi
  for zone in "${zones[@]}"; do
    if ! [[ $zone =~ $LEVEL_ZONE_RE ]]; then
      echo "RIFTAL_LEVEL_ZONES zone '$zone' is not a name matching [a-z0-9_]+"
      found=1
    elif [ -n "${seen[$zone]+x}" ]; then
      echo "RIFTAL_LEVEL_ZONES lists zone $zone more than once"
      found=1
    else
      seen[$zone]=1
    fi
  done
  return "$found"
}

# $1 RIFTAL_LEVEL_ZONES. Prints each valid zone once, in order.
level_zone_list() {
  local zone zones
  local -A seen=()
  read -ra zones <<<"${1-}"
  for zone in "${zones[@]}"; do
    if [[ $zone =~ $LEVEL_ZONE_RE ]] && [ -z "${seen[$zone]+x}" ]; then
      seen[$zone]=1
      echo "$zone"
    fi
  done
}

# $1 POCKETMINE_ARGS, unset or empty when missing, $2 RIFTAL_LEVEL_ZONES.
level_args_findings() {
  local value="${1-}" token names=() odd=0 found=0 args zone in_list=0
  if [ -z "$value" ]; then
    echo "POCKETMINE_ARGS is unset or empty"
    return 1
  fi
  if ! [[ $value =~ $LEVEL_VALUE_RE ]]; then
    echo "POCKETMINE_ARGS holds a character outside letters, digits, space and _ . , : = / @ + -"
    return 1
  fi
  read -ra args <<<"$value"
  for token in "${args[@]}"; do
    if ! [[ $token =~ $LEVEL_OPTION_RE ]]; then
      echo "POCKETMINE_ARGS token '$token' is not a single long option, so core stops reading options there and takes no --level-name after it"
      odd=1
      found=1
      break
    fi
    case "$token" in
      --level-name=?*) names+=("${token#--level-name=}") ;;
      --level-name*)
        echo "POCKETMINE_ARGS token '$token' is not --level-name=<zone>, so core would not take it as a name"
        odd=1
        found=1
        ;;
      --worlds*)
        echo "POCKETMINE_ARGS token '$token' would generate the levels it lists"
        found=1
        ;;
    esac
  done
  if [ "${#names[@]}" -gt 1 ]; then
    echo "POCKETMINE_ARGS holds ${#names[@]} --level-name tokens, and exactly one is allowed"
    found=1
  elif [ "${#names[@]}" -eq 0 ] && [ "$odd" -eq 0 ]; then
    echo "POCKETMINE_ARGS holds no --level-name=<zone>, so core would generate the default level"
    found=1
  elif [ "${#names[@]}" -eq 1 ]; then
    while IFS= read -r zone; do
      [ "$zone" != "${names[0]}" ] || in_list=1
    done < <(level_zone_list "${2-}")
    if [ "$in_list" -eq 0 ]; then
      echo "--level-name zone '${names[0]}' is not in RIFTAL_LEVEL_ZONES, so boot would generate it"
      found=1
    fi
  fi
  return "$found"
}

# $1 RIFTAL_LEVEL_ZONES, $2 POCKETMINE_ARGS.
level_findings() {
  local zones_found=0 args_found=0
  level_zones_findings "${1-}" || zones_found=1
  level_args_findings "${2-}" "${1-}" || args_found=1
  [ $((zones_found + args_found)) -eq 0 ]
}
