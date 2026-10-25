#!/usr/bin/env bash
# Refuses an alpha or production instance definition whose levels are not all
# built zones (riftal-infra#1113, ADR 009 items 5 and 7): a fresh volume must
# never boot generator terrain, and every wipe of it must be able to re-seed.
# It only reads files, and takes no arguments.
#
# Each subdirectory of INSTANCES_DIR is one definition and holds exactly image
# and instance.env. The container's environment comes from instance.env, which
# `docker run --env-file` and compose `env_file:` read the same way only within
# one grammar: each line is blank, a # comment from column 1, or KEY=VALUE, with
# KEY matching [A-Z][A-Z0-9_]* and VALUE non-empty, of letters, digits, space
# and _ . , : = / @ + - only. A repeated key is refused. Required, each once:
#
#   RIFTAL_LEVEL_ZONES  the zones seed-levels.sh copies in, split on whitespace.
#                       Each matches [a-z0-9_]+, none repeats, and no other
#                       definition lists it.
#   POCKETMINE_ARGS     split on whitespace as start-instance.sh splits it.
#                       Exactly one --level-name=<zone>, and no --worlds token.
#                       Core reads --level-name as an optional-value option, so
#                       a bare one is no name and boot would generate "world".
#
# The rule: the --level-name zone is in RIFTAL_LEVEL_ZONES, and every zone there
# is built. A zone is built when LEVEL_LOCKS_DIR/<zone>.lock.json is a regular
# file holding one JSON object whose .zone is <zone> and whose .content_sha256 is
# 64 lowercase hex digits (the keys designer/designer/level.py writes). Levels a
# plugin loads by its own config are not read here.
#
# Environment: INSTANCES_DIR (default instances/ beside deploy/), LEVEL_LOCKS_DIR
# (default designer/levels beside deploy/), JQ_BIN (default /usr/bin/jq).
#
# Exit status: 0 one INSTANCE LEVELS OK line, also for zero definitions; 1 one
# INSTANCE LEVELS REFUSED line per finding; 2 usage, an unreadable instance.env,
# a directory that is not one, or a missing jq. Never a pass on 2.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${INSTANCES_DIR:-$SCRIPT_DIR/../instances}"
LEVEL_LOCKS_DIR="${LEVEL_LOCKS_DIR:-$SCRIPT_DIR/../designer/levels}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"

die() {
  echo "instance-levels-check.sh: $1" >&2
  exit 2
}

[ "$#" -eq 0 ] || die 'usage: instance-levels-check.sh (it takes no arguments)'
[ -d "$INSTANCES_DIR" ] || die "cannot read instance definitions in $INSTANCES_DIR"
[ -d "$LEVEL_LOCKS_DIR" ] || die "$LEVEL_LOCKS_DIR is not a directory, so no zone's build can be read"
[ -x "$JQ_BIN" ] || die "$JQ_BIN is not an executable jq, so no build lock can be read"

INSTANCES_DIR="${INSTANCES_DIR%/}"
refused=0
refuse() {
  printf 'INSTANCE LEVELS REFUSED: %s\n' "$1"
  refused=1
}

value_re='^[A-Za-z0-9 _.,:=/@+-]+$'
declare -A zone_owner=()
declare -A env_value=()
definitions=0
built=()
listed=()
default_zone=

# lock_problem <zone> prints why the zone has no build, or nothing when it has.
lock_problem() {
  local lock="$LEVEL_LOCKS_DIR/$1.lock.json" named sha
  [ -f "$lock" ] || { echo "has no build: $lock is not a regular file"; return; }
  "$JQ_BIN" -e -s 'length == 1 and (.[0] | type == "object")' "$lock" >/dev/null 2>&1 \
    || { echo "has no build: $lock is not one JSON object"; return; }
  named="$("$JQ_BIN" -r '(.zone | strings) // ""' "$lock")"
  [ "$named" = "$1" ] || { echo "has no build: $lock names zone '$named'"; return; }
  sha="$("$JQ_BIN" -r '(.content_sha256 | strings) // ""' "$lock")"
  [[ $sha =~ ^[0-9a-f]{64}$ ]] || echo "has no build: $lock holds no 64-digit lowercase hex content_sha256"
}

# read_env <id> <file> fills env_value, or refuses what it cannot take.
read_env() {
  local id="$1" file="$2" line key value n=0
  env_value=()
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    [ "${line:0:1}" != '#' ] || continue
    if ! [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      refuse "$id: instance.env:$n is not blank, a # comment or KEY=VALUE"
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [ -n "${env_value[$key]+x}" ]; then
      refuse "$id: instance.env:$n repeats $key"
    elif [ -z "$value" ]; then
      refuse "$id: instance.env:$n gives $key an empty value"
    elif ! [[ $value =~ $value_re ]]; then
      refuse "$id: instance.env:$n gives $key a character outside letters, digits, space and _ . , : = / @ + -"
    else
      env_value[$key]="$value"
    fi
  done <"$file"
}

# check_args <id> sets default_zone from POCKETMINE_ARGS, empty when there is none.
check_args() {
  local id="$1" token names=() odd=0 args
  default_zone=
  read -ra args <<<"${env_value[POCKETMINE_ARGS]}"
  for token in "${args[@]}"; do
    case "$token" in
      --level-name=?*) names+=("${token#--level-name=}") ;;
      --level-name*)
        refuse "$id: POCKETMINE_ARGS token '$token' is not --level-name=<zone>, so core would not take it as a name"
        odd=1 ;;
      --worlds*) refuse "$id: POCKETMINE_ARGS token '$token' would generate the levels it lists" ;;
    esac
  done
  if [ "${#names[@]}" -gt 1 ]; then
    refuse "$id: POCKETMINE_ARGS holds ${#names[@]} --level-name tokens, and exactly one is allowed"
  elif [ "${#names[@]}" -eq 0 ] && [ "$odd" -eq 0 ]; then
    refuse "$id: POCKETMINE_ARGS holds no --level-name=<zone>, so core would generate the default level"
  fi
  [ "${#names[@]}" -ne 1 ] || default_zone="${names[0]}"
}

# check_zones <id> sets listed to the valid zones in RIFTAL_LEVEL_ZONES.
check_zones() {
  local id="$1" zone zones
  declare -A seen=()
  listed=()
  read -ra zones <<<"${env_value[RIFTAL_LEVEL_ZONES]}"
  if [ "${#zones[@]}" -eq 0 ]; then
    refuse "$id: RIFTAL_LEVEL_ZONES lists no zone"
    return
  fi
  for zone in "${zones[@]}"; do
    if ! [[ $zone =~ ^[a-z0-9_]+$ ]]; then
      refuse "$id: RIFTAL_LEVEL_ZONES zone '$zone' is not a name matching [a-z0-9_]+"
    elif [ -n "${seen[$zone]+x}" ]; then
      refuse "$id: RIFTAL_LEVEL_ZONES lists zone $zone more than once"
    elif [ -n "${zone_owner[$zone]+x}" ]; then
      refuse "$id: zone $zone is also listed by ${zone_owner[$zone]}, and two instances never list the same zone"
    else
      seen[$zone]=1
      zone_owner[$zone]="$id"
      listed+=("$zone")
    fi
  done
}

shopt -s nullglob dotglob
for entry in "$INSTANCES_DIR"/*; do
  id="${entry##*/}"
  if [ ! -d "$entry" ]; then
    [ "$id" = .gitkeep ] || refuse "$id: is not a directory, and an instance definition is a directory"
    continue
  fi
  definitions=$((definitions + 1))
  for file in "$entry"/*; do
    case "${file##*/}" in
      image | instance.env) [ -f "$file" ] || refuse "$id: ${file##*/} is not a regular file" ;;
      *) refuse "$id: holds ${file##*/}, and a definition holds only image and instance.env" ;;
    esac
  done
  [ -e "$entry/image" ] || refuse "$id: has no image file"
  if [ ! -e "$entry/instance.env" ]; then
    refuse "$id: has no instance.env"
    continue
  fi
  [ -f "$entry/instance.env" ] && [ -r "$entry/instance.env" ] || die "cannot read $entry/instance.env"

  read_env "$id" "$entry/instance.env"
  for key in RIFTAL_LEVEL_ZONES POCKETMINE_ARGS; do
    [ -n "${env_value[$key]+x}" ] || refuse "$id: instance.env sets no $key"
  done
  [ -n "${env_value[RIFTAL_LEVEL_ZONES]+x}" ] && [ -n "${env_value[POCKETMINE_ARGS]+x}" ] || continue

  check_zones "$id"
  check_args "$id"
  if [ -n "$default_zone" ]; then
    in_list=0
    for zone in "${listed[@]}"; do
      [ "$zone" != "$default_zone" ] || in_list=1
    done
    [ "$in_list" -eq 1 ] || refuse "$id: --level-name zone '$default_zone' is not in RIFTAL_LEVEL_ZONES, so boot would generate it"
  fi
  for zone in "${listed[@]}"; do
    problem="$(lock_problem "$zone")"
    if [ -n "$problem" ]; then
      refuse "$id: zone $zone $problem"
    else
      built+=("$zone")
    fi
  done
done
shopt -u nullglob dotglob

[ "$refused" -eq 0 ] || exit 1
printf 'INSTANCE LEVELS OK: %s instance definition(s) read, %s built zone(s): %s
'   "$definitions" "${#built[@]}" "${built[*]:-none}"
