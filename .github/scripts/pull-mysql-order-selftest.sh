#!/usr/bin/env bash
# Proves pull-mysql-order.sh can fail. Its only real input is ci.yml, which
# passes, so without these cases a check that never found a mysql:8 step, or
# never compared positions, would look the same. Reads and writes files in a
# temporary directory only and starts no container.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$dir/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
ran=0
expected=13

root="$work/root"
mkdir -p "$root/.github/scripts" "$root/sub"
# The fixtures name the engine through %s, so this file never spells out a
# container start beside mysql:8 and is not itself read as a step that runs it.
engine=docker
printf '%s pull mysql:8\n' "$engine" >"$root/.github/scripts/pull-mysql.sh"
printf '%s run --rm -m 1g mysql:8 true\n' "$engine" >"$root/db.sh"
# start.sh runs mysql:8 only under sub/, so a checker that ignores a step's
# working-directory reads the root copy and finds no mysql:8 step at all.
printf '%s run -d \\\n  mysql:8 >/dev/null\n' "$engine" >"$root/sub/start.sh"
printf '%s run --rm php:8.3-cli-alpine true\n' "$engine" >"$root/start.sh"
printf '%s run --rm php:8.3-cli-alpine true\n' "$engine" >"$root/php.sh"
printf '# %s run --rm mysql:8 true\n%s run --rm php:8.3-cli-alpine true\n' "$engine" "$engine" >"$root/comment.sh"
printf "expect 'pull mysql:8'\n" >"$root/named.sh"

# Prints a workflow with one job per argument group. Each step is name=run,
# and a job starts at an argument job:<key>.
workflow() {
  local arg
  printf 'name: CI\non:\n  pull_request:\njobs:\n'
  for arg in "$@"; do
    case "$arg" in
      job:*) printf '  %s:\n    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n    steps:\n' "${arg#job:}" ;;
      *) printf '      - name: %s\n        run: %s\n' "${arg%%=*}" "${arg#*=}" ;;
    esac
  done
}

# Each case names the line it must print, so a refusal for the wrong reason, or
# a pass that counted the wrong steps, does not count.
expect() {
  local label="$1" status="$2" want="$3" file="$4" base="$5" out rc
  ran=$((ran + 1))
  out="$(bash "$dir/pull-mysql-order.sh" "$file" "$base" 2>&1)"
  rc=$?
  if [[ "$out" == *"$want"* ]] &&
    { { [ "$status" = pass ] && [ "$rc" -eq 0 ]; } ||
      { [ "$status" = fail ] && [ "$rc" -ne 0 ]; }; }; then
    printf '  ok    %s, %s\n' "$label" "$status"
  else
    printf "::error::%s: want %s with '%s', got exit %s with '%s'\n" "$label" "$status" "$want" "$rc" "$out"
    failures=$((failures + 1))
  fi
}

pull='pull=bash .github/scripts/pull-mysql.sh'

workflow job:a "php=bash php.sh" "$pull" "db=bash db.sh" >"$work/good.yml"
expect "pull before the mysql step" pass 'precedes all 1 step(s)' "$work/good.yml" "$root"

workflow job:a "db=bash db.sh" "$pull" >"$work/late.yml"
expect "pull below a mysql step" fail "step 'db' runs mysql:8 before .github/scripts/pull-mysql.sh in job a" "$work/late.yml" "$root"

workflow job:a "php=bash php.sh" "db=bash db.sh" >"$work/nopull.yml"
expect "no pull step" fail 'no step runs .github/scripts/pull-mysql.sh' "$work/nopull.yml" "$root"

workflow job:a "$pull" "php=bash php.sh" >"$work/nomysql.yml"
expect "no step runs mysql:8" fail 'found no step that runs mysql:8' "$work/nomysql.yml" "$root"

workflow job:a "comment=bash comment.sh" "named=bash named.sh" "$pull" "db=bash db.sh" >"$work/mentions.yml"
expect "a comment or a bare name is not a run" pass 'precedes all 1 step(s)' "$work/mentions.yml" "$root"

{
  workflow job:a "php=bash php.sh"
  printf '      - name: inline\n        run: |\n          %s run --rm \\\n            mysql:8 true\n' "$engine"
  workflow "$pull" "db=bash db.sh" | sed 1,4d
} >"$work/inline.yml"
expect "inline run block before the pull" fail "step 'inline' runs mysql:8 before" "$work/inline.yml" "$root"

{
  workflow job:a "php=bash php.sh"
  printf '      - name: subdir\n        working-directory: sub\n        run: bash start.sh\n'
  workflow "$pull" | sed 1,4d
} >"$work/subdir.yml"
expect "working-directory script before the pull" fail "step 'subdir' runs mysql:8 before" "$work/subdir.yml" "$root"

workflow job:a "$pull" "db=bash db.sh" job:b "db2=bash db.sh" >"$work/twojobs.yml"
expect "pull in another job" fail "step 'db2' runs mysql:8 before .github/scripts/pull-mysql.sh in job b" "$work/twojobs.yml" "$root"

# A real mysql:8 step after the pull, so the only reason left to fail is the
# script that cannot be read.
workflow job:a "$pull" "db=bash db.sh" "gone=bash absent.sh" >"$work/absent.yml"
expect "a script that is not there" fail 'absent.sh, which cannot be read' "$work/absent.yml" "$root"

expect "missing workflow" fail 'cannot read' "$work/none.yml" "$root"

real="$repo/.github/workflows/ci.yml"
expect "the real workflow" pass 'after the pull: Wipe self-test' "$real" "$repo"

# The real workflow with its pull step cut out, and with that step put back
# below the last mysql self-test. A mutation that missed would pass for the
# wrong reason, so each copy is checked to differ the way it must.
awk '/^      - name: Pull mysql:8$/ { getline; next } { print }' "$real" >"$work/real-deleted.yml"
if grep -q 'pull-mysql.sh' "$work/real-deleted.yml"; then
  printf '::error::the pull step was not cut from the copy of ci.yml\n'
  failures=$((failures + 1))
fi
expect "real workflow, pull step deleted" fail 'no step runs .github/scripts/pull-mysql.sh' "$work/real-deleted.yml" "$repo"

awk '
  /^      - name: Pull mysql:8$/ { held = $0; getline; held = held "\n" $0; next }
  { print }
  /^        run: bash deploy\/wipe-selftest.sh$/ { print held }' "$real" >"$work/real-moved.yml"
if [ "$(grep -n 'pull-mysql.sh$' "$work/real-moved.yml" | cut -d: -f1)" != \
  "$(($(grep -n 'deploy/wipe-selftest.sh$' "$work/real-moved.yml" | cut -d: -f1) + 2))" ]; then
  printf '::error::the pull step was not moved below the wipe self-test in the copy of ci.yml\n'
  failures=$((failures + 1))
fi
expect "real workflow, pull moved below the mysql self-tests" fail \
  "step 'Migration runner self-test' runs mysql:8 before" "$work/real-moved.yml" "$repo"

if [ "$ran" -ne "$expected" ]; then
  printf '::error::ran %d of %d cases\n' "$ran" "$expected"
  exit 1
fi
if [ "$failures" -ne 0 ]; then
  printf '::error::%d of %d cases failed\n' "$failures" "$ran"
  exit 1
fi
printf 'all %d cases behaved\n' "$ran"
