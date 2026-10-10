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
expected=55

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
cp "$root/db.sh" "$root/db"
printf '%s run --rm mysql:8 true\n' podman >"$root/podman.sh"
printf '%s run --rm mysql:8 true\n' /usr/local/bin/Docker >"$root/cased.sh"
printf '%s run --rm mysql:8 true\n' '"${engine}"' >"$root/var.sh"
printf '%s --context x run --rm mysql:8 true\n' "$engine" >"$root/flag.sh"
printf '%s run --rm docker.io/library/mysql:8 true\n' "$engine" >"$root/registry.sh"
printf '%s compose -f compose.yaml up -d mysql\n' "$engine" >"$root/compose.sh"

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

# Each form of a mysql:8 start, or of a script that holds one, placed before
# the pull with a plain mysql:8 step after it, so the only way to fail is to
# see the first step.
for form in "direct=./db" 'flagged=bash -e "db"' "quoted=bash 'db.sh'" 'yaml="bash db"' \
  "podman=bash podman.sh" "cased=bash cased.sh" "variable=bash var.sh" "global flag=bash flag.sh" \
  "registry=bash registry.sh" "compose=bash compose.sh" \
  "bundled o=bash -euo pipefail db" "lone o=bash -o pipefail db" "dot=. ./db" "source=source ./db" \
  'braced="{ bash db; }"' "command=command bash db" "timeout kill=timeout -k 5 10 bash db" \
  "rcfile=bash --rcfile php.sh db"; do
  workflow job:a "$form" "$pull" "db=bash db.sh" >"$work/form.yml"
  expect "${form%%=*} before the pull" fail "step '${form%%=*}' runs mysql:8 before" "$work/form.yml" "$root"
done

# A run scalar continued on more-indented lines is one command, bash db.
for form in 'plain|bash\n          db' 'double quoted|"bash\n          db"' 'folded|>\n          bash\n          db'; do
  {
    workflow job:a
    printf "      - name: lines\n        run: ${form#*|}\n"
    workflow "$pull" "db=bash db.sh" | sed 1,4d
  } >"$work/lines.yml"
  expect "${form%%|*} run over two lines before the pull" fail "step 'lines' runs mysql:8 before" "$work/lines.yml" "$root"
done

# The image is named only in env:, at each level it can be set.
envrun="$(printf '%s run --rm "$IMAGE" true' "$engine")"
{
  workflow job:a
  printf '      - name: env\n        env: { IMAGE: mysql:8 }\n        run: %s\n' "$envrun"
  workflow "$pull" "db=bash db.sh" | sed 1,4d
} >"$work/env.yml"
expect "step env: before the pull" fail "step 'env' runs mysql:8 before" "$work/env.yml" "$root"
workflow job:a "env=$envrun" "$pull" "db=bash db.sh" |
  sed 's/^    steps:$/    env:\n      IMAGE: mysql:8\n    steps:/' >"$work/env.yml"
expect "job env: before the pull" fail "step 'env' runs mysql:8 before" "$work/env.yml" "$root"
workflow job:a "env=$envrun" "$pull" "db=bash db.sh" | sed 's/^jobs:$/env:\n  IMAGE: mysql:8\njobs:/' >"$work/env.yml"
expect "workflow env: before the pull" fail "step 'env' runs mysql:8 before" "$work/env.yml" "$root"

# start.sh at the root runs php only, so reading it in place of sub/start.sh
# finds nothing.
workflow job:a "cd=cd sub && ./start.sh" "$pull" "db=bash db.sh" >"$work/cd.yml"
expect "cd before a script" fail "step 'cd' changes directory before running" "$work/cd.yml" "$root"

for cond in 'always()' '${{ failure() }}'; do
  workflow job:a "$pull" "db=bash db.sh" | sed "s/^      - name: db\$/&\n        if: $cond/" >"$work/if.yml"
  expect "mysql step after the pull with if: $cond" fail "step 'db' runs mysql:8 under if:" "$work/if.yml" "$root"
done

badroot="$work/badroot"
cp -r "$root" "$badroot"
printf '%s run --rm mysql:8 true\n' "$engine" >"$badroot/.github/scripts/pull-mysql.sh"
workflow job:a "$pull" "db=bash db.sh" >"$work/pull-self.yml"
expect "a pull script that runs mysql:8" fail "pull step 'pull' runs mysql:8 itself" "$work/pull-self.yml" "$badroot"

workflow job:a "$pull" "db=bash db.sh" "prose=echo built with sh today" >"$work/prose.yml"
expect "a sh word in prose is not a script" pass 'precedes all 1 step(s)' "$work/prose.yml" "$root"

{
  workflow job:a
  printf '      - name: image\n        uses: docker://mysql:8\n'
  workflow "$pull" "db=bash db.sh" | sed 1,4d
} >"$work/uses.yml"
expect "uses: docker:// before the pull" fail "step 'image' runs mysql:8 before" "$work/uses.yml" "$root"
for q in '"' "'"; do
  sed "s|uses: docker://mysql:8|uses: ${q}docker://mysql:8${q}|" "$work/uses.yml" >"$work/uses-quoted.yml"
  expect "uses: ${q}docker://${q} before the pull" fail "step 'image' runs mysql:8 before" "$work/uses-quoted.yml" "$root"
done

for key in 'services:\n      db:\n        image: mysql:8' 'container: ubuntu:24.04'; do
  workflow job:a "$pull" "db=bash db.sh" | sed "s/^    steps:\$/    $key\n    steps:/" >"$work/job-key.yml"
  expect "job-level ${key%%:*}" fail 'sets services: or container:' "$work/job-key.yml" "$root"
done

workflow job:a "$pull" "db=bash start.sh" | sed 's/^jobs:$/defaults:\n  run:\n    working-directory: sub\njobs:/' >"$work/defaults.yml"
expect "workflow defaults working-directory" fail 'working-directory: outside a step' "$work/defaults.yml" "$root"
workflow job:a "$pull" "db=bash start.sh" |
  sed 's/^    steps:$/    defaults:\n      run:\n        working-directory: sub\n    steps:/' >"$work/job-defaults.yml"
expect "job defaults working-directory" fail 'working-directory: outside a step' "$work/job-defaults.yml" "$root"

workflow job:a "$pull" "db=bash db.sh" job:b "db2=bash db.sh" "$pull" |
  sed '/^  b:$/,$ s/^    steps:$/    steps: # b/' >"$work/steps-comment.yml"
expect "a steps: line with a comment" fail "step 'db2' runs mysql:8 before .github/scripts/pull-mysql.sh in job b" \
  "$work/steps-comment.yml" "$root"

workflow job:a "$pull" "db=bash db.sh" job:b "db2=bash db.sh" | sed '5,$ s/^/  /' >"$work/indent.yml"
expect "jobs indented four spaces" fail "step 'db2' runs mysql:8 before .github/scripts/pull-mysql.sh in job b" \
  "$work/indent.yml" "$root"

workflow job:a "echoed=echo .github/scripts/pull-mysql.sh" "db=bash db.sh" >"$work/echoed.yml"
expect "an echoed pull path" fail "step 'echoed' names .github/scripts/pull-mysql.sh but is not" "$work/echoed.yml" "$root"

workflow job:a "both=bash .github/scripts/pull-mysql.sh; bash db.sh" "db=bash db.sh" >"$work/both.yml"
expect "a pull step that also runs mysql:8" fail "step 'both' runs mysql:8 before" "$work/both.yml" "$root"

for key in 'if: false' 'continue-on-error: true'; do
  workflow job:a "$pull" "db=bash db.sh" | sed "s/^      - name: pull\$/&\n        $key/" >"$work/cond.yml"
  expect "pull step with ${key%%:*}:" fail "pull step 'pull' sets ${key%%:*}:" "$work/cond.yml" "$root"
done

real="$repo/.github/workflows/ci.yml"
expect "the real workflow" pass 'precedes all 5 step(s)' "$real" "$repo"

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
