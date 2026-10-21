#!/usr/bin/env bash
# Proves bot-proofs-scope.sh can fail (riftal-infra#1231). Reads no file of this
# checkout and starts no container: classification cases take a NUL-separated
# path list, and diff cases run against a repository made in a temporary
# directory.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/bot-proofs-scope.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=35
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 case, $2 wanted verdict, the rest are the paths.
classify() {
  local what="$1" want="$2" out
  shift 2
  out="$(printf '%s\0' "$@" | scope_classify)"
  if [ "$(tail -n 1 <<<"$out")" = "serves=$want" ]; then
    pass "$what: serves=$want"
  else
    fail "$what: wanted serves=$want, got: $out"
  fi
}

classify "docs only" false docs/design.md docs/specs/a/b.txt
classify "designer, proxy and a root md file" false designer/stack/compose.yaml proxy/config.yml README.md CLAUDE.md
classify "a lone proxy file" false proxy/servers.yml
for path in .github/workflows/ci.yml .github/scripts/scan.sh images/compose.yaml deploy/restore.sh \
  migrations/001.sql instances/mine-h/image tools/new.sh Makefile compose.yaml .env.example; do
  classify "serving path $path" true "$path"
done
classify "docs beside images" true docs/a.md images/compose.yaml
classify "a serving path last" true README.md designer/a.py deploy/x.sh
classify "a root file named docs" true docs
classify "a root md under a serving name" true images.md.sh
classify "no path" true

out="$(printf '::error::x\0docs/a\nb.md\0' | scope_classify)"
if ! grep -q '^::' <<<"$out" && grep -qF 'changed ::error::x' <<<"$out"; then
  pass "a hostile path never starts a line"
else
  fail "a hostile path started a line: $out"
fi

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
repo="$work/repo"
git init -q -b main "$repo"
cd "$repo" || exit 1
mkdir docs images deploy
printf 'a\n' > docs/a.md
printf 'a\n' > images/compose.yaml
printf 'a\n' > deploy/run.sh
printf 'a\n' > README.md
git add -A
git commit -q -m base
base="$(git rev-parse HEAD)"

# $1 branch, the rest are file edits as path=content; content - deletes.
branch() {
  local name="$1" edit
  shift
  git checkout -q -b "$name" "$base"
  for edit in "$@"; do
    if [ "${edit#*=}" = - ]; then
      git rm -q "${edit%%=*}"
    else
      mkdir -p "$(dirname "${edit%%=*}")"
      printf '%s\n' "${edit#*=}" > "${edit%%=*}"
    fi
  done
  git add -A
  git commit -q -m "$name"
  git rev-parse HEAD
}

# $1 case, $2 wanted verdict, $3 event, $4 base, $5 head, $6 text the output must hold
run() {
  local what="$1" want="$2" resultfile="$work/verdict" out
  : > "$resultfile"
  out="$(scope_run "$3" "$4" "$5" "$resultfile" 2>&1)"
  if [ "$(cat "$resultfile")" = "serves=$want" ] && grep -qF -- "$6" <<<"$out"; then
    pass "$what: serves=$want"
  else
    fail "$what: wanted serves=$want with \"$6\", got file \"$(cat "$resultfile")\", output: $out"
  fi
}

head="$(branch docs-only docs/b.md=b README.md=b)"
run "pull request touching only docs and a root md file" false pull_request "$base" "$head" "changed docs/b.md"
run "push touching only docs" false push "$base" "$head" "changed README.md"

head="$(branch mixed docs/c.md=c deploy/new.sh=c)"
run "pull request with docs and deploy" true pull_request "$base" "$head" "changed deploy/new.sh"

head="$(branch deleted images/compose.yaml=-)"
run "a serving file deleted" true pull_request "$base" "$head" "changed images/compose.yaml"

# Same content under a new name, which git reports as a rename into docs/.
git checkout -q -b moved "$base"
mkdir -p docs/moved
git mv deploy/run.sh docs/moved/run.sh
git commit -q -m moved
head="$(git rev-parse HEAD)"
run "a serving file moved into docs" true pull_request "$base" "$head" "changed deploy/run.sh"

# main moves on under the pull request; only the pull request's own paths count.
git checkout -q -b main-moved "$base"
printf 'b\n' > images/compose.yaml
git commit -q -a -m moved-on
moved="$(git rev-parse HEAD)"
head="$(branch docs-after-base docs/d.md=d)"
run "three-dot diff ignores what main changed" false pull_request "$moved" "$head" "changed docs/d.md"
run "two-dot diff on a push sees what main changed" true push "$moved" "$head" "changed images/compose.yaml"

missing="$(printf 'f%.0s' $(seq 1 40))"
run "a base commit that does not exist" true pull_request "$missing" "$base" "git diff"
run "a head commit that does not exist" true push "$base" "$missing" "git diff"
run "an all-zero before" true push "$(printf '0%.0s' $(seq 1 40))" "$base" "not both usable"
run "an empty before" true push "" "$base" "not both usable"
run "an empty head" true pull_request "$base" "" "not both usable"
run "a base that is not a sha" true pull_request "main" "$base" "not both usable"
run "an empty diff" true pull_request "$base" "$base" "no changed path"
run "an event this check does not read" true workflow_dispatch "$base" "$head" "not one this check reads"

verdicts="$work/once"
: > "$verdicts"
head="$(git rev-parse docs-only)"
scope_run pull_request "$base" "$head" "$verdicts" > /dev/null
if [ "$(wc -l < "$verdicts" | tr -d ' ')" = 1 ]; then
  pass "the verdict is written once"
else
  fail "the verdict was not written once: $(cat "$verdicts")"
fi

total=$((PASSES + FAILURES))
if [ "$FAILURES" -ne 0 ] || [ "$total" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '::error::%s failed, %s ran, %s expected\n' "$FAILURES" "$total" "$EXPECTED_ASSERTIONS"
  exit 1
fi
printf 'bot-proofs-scope.sh refuses every mutant for its own reason (%s assertions)\n' "$total"
