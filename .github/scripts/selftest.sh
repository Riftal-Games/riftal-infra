#!/usr/bin/env bash
# Self-test for the CI checks.
#
# A check never observed printing anything is decoration. Each rule below gets
# input it must reject and input it must accept, driven through scan.sh itself
# rather than a second copy of its hadolint and `docker compose` calls, and
# part of this file drives scan.sh with no root or prune argument at all, the
# exact way ci.yml invokes it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$REPO_ROOT/.github/ci-fixtures"
LIST="$REPO_ROOT/.github/scripts/list_compose.sh"
SCAN="$REPO_ROOT/.github/scripts/scan.sh"
# In CI, HADOLINT comes from install-hadolint.sh, and falling back to PATH
# would lint with a binary this job never checked.
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  : "${HADOLINT:?HADOLINT is unset, install-hadolint.sh did not reach this step}"
fi
export HADOLINT="${HADOLINT:-hadolint}"
FAILURES=0
PASSES=0
# Every assertion below must run. A harness that quietly runs fewer and still
# prints its closing line is the exact failure it exists to catch.
EXPECTED_ASSERTIONS=179

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$1"; }

# Both of these run the fixture through scan.sh itself, root set to the
# fixture file, so hadolint or `docker compose config` is reached through the
# real check_dockerfiles/check_compose and the real loop, not a second copy
# of the call living only in this file. A file as root works: find(1) tests a
# file argument directly against the same predicates it would apply inside a
# directory.
expect_scan_ok() {
  local kind="$1" file="$2" out status
  out="$(bash "$SCAN" "$kind" "$file" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -qF "checking $file"; then
    pass "$(rel "$file") checks clean through scan.sh $kind"
  else
    fail "expected $(rel "$file") to check clean through scan.sh $kind, exit $status"
    printf '%s\n' "$out"
  fi
}

# The needle is the fixture's own defect. Reject-because-the-tool-is-missing
# is caught by the expect_scan_ok sites above, which go red in that case too.
expect_scan_bad() {
  local kind="$1" file="$2" needle="$3" out status
  out="$(bash "$SCAN" "$kind" "$file" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qi "$needle"; then
    pass "$(rel "$file") rejected through scan.sh $kind, naming $needle"
  else
    fail "expected $(rel "$file") to be rejected through scan.sh $kind naming $needle, exit $status"
    printf '%s\n' "$out"
  fi
}

# ci.yml calls scan.sh with a kind and nothing else: no root, no prune
# argument, both left to scan.sh's own defaults. Every assertion above passes
# an explicit root, so none of them would notice a broken default. This plants
# a file outside .github/ci-fixtures, runs scan.sh exactly the way ci.yml
# does, and checks both properties a wrong root or a wrong prune would break:
# the planted file is discovered, and the fixtures tree, which is bad enough
# to fail every check, is not.
PLANTED_DIR="$REPO_ROOT/.ci-realscan-planted"

expect_real_scan() {
  local kind="$1" fixture="$2" name out status
  name="$(basename "$fixture")"
  mkdir -p "$PLANTED_DIR"
  cp "$fixture" "$PLANTED_DIR/$name"
  out="$(cd "$REPO_ROOT" && bash "$SCAN" "$kind" 2>&1)"
  status=$?
  rm -rf "$PLANTED_DIR"
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -qF "checking ./.ci-realscan-planted/$name" \
    && ! printf '%s' "$out" | grep -q 'ci-fixtures'; then
    pass "the real $kind invocation finds a planted file and excludes ci-fixtures"
  else
    fail "expected the real $kind invocation (no root, no prune argument) to find the planted file and exclude ci-fixtures, exit $status"
    printf '%s\n' "$out"
  fi
}

# Discovery is a check in its own right. A compose file nothing looks at is
# validated by nothing and reported as success, which reads exactly like clean.
expect_listed() {
  local out
  out="$(bash "$LIST" "$1")"
  if printf '%s\n' "$out" | grep -q "/$2\$"; then
    pass "discovery lists $2"
  else
    fail "expected $2 in the compose list of $(rel "$1")"
    printf '%s\n' "$out"
  fi
}

expect_not_listed() {
  local out
  out="$(bash "$LIST" "$1")"
  if printf '%s\n' "$out" | grep -q "/$2\$"; then
    fail "$2 is not compose and must not be handed to docker compose"
    printf '%s\n' "$out"
  else
    pass "discovery skips $2"
  fi
}

# Dockerfile discovery is by name, so a widened pattern hands hadolint files
# that are not Dockerfiles. HADOLINT=true keeps this case free of hadolint:
# what decides it is the found count and the absence of a checking line, never
# the lint result.
expect_dockerfile_skipped() {
  local dir out status
  dir="$(mktemp -d)"
  printf 'FROM ubuntu:24.04\n' > "$dir/$1"
  out="$(HADOLINT=true bash "$SCAN" dockerfiles "$dir" 2>&1)"
  status=$?
  rm -rf "$dir"
  if [ "$status" -eq 0 ] \
    && printf '%s' "$out" | grep -qF 'found 0 ' \
    && ! printf '%s' "$out" | grep -qF "checking"; then
    pass "Dockerfile discovery skips $1"
  else
    fail "$1 is not a Dockerfile or Containerfile name and must not be handed to hadolint, exit $status"
    printf '%s\n' "$out"
  fi
}

# Each dotted name form is its own -iname alternative in scan.sh, so each needs
# its own case: dropping one alternative leaves the bare names and every other
# form still found. Each form also needs a spelling only a case-insensitive
# match finds, or narrowing one alternative to -name leaves every case green.
expect_dockerfile_found() {
  local dir out status
  dir="$(mktemp -d)"
  printf 'FROM ubuntu:24.04\n' > "$dir/$1"
  out="$(HADOLINT=true bash "$SCAN" dockerfiles "$dir" 2>&1)"
  status=$?
  rm -rf "$dir"
  if [ "$status" -eq 0 ] \
    && printf '%s' "$out" | grep -qF 'found 1 ' \
    && printf '%s' "$out" | grep -qF "checking $dir/$1"; then
    pass "Dockerfile discovery finds $1"
  else
    fail "$1 is a Dockerfile or Containerfile name and must be handed to hadolint, exit $status"
    printf '%s\n' "$out"
  fi
}

# Created neither in C order nor its reverse, so neither a filesystem that
# lists by creation time nor one that lists newest first hands find(1) the
# expected order. The expected list is written out rather than computed with
# sort, and it differs from a locale-aware collation: uppercase before
# underscore before lowercase, space before dot, and b.Dockerfile before
# b/Dockerfile.
#
# The scan runs under COLLATING_LOCALE with FAKE_SORT loaded through BASH_ENV,
# so a bare sort in scan.sh folds case and only scan.sh pinning its own
# LC_ALL=C gives the expected list, whichever sort and locales the host has.
# The first check runs the stub the same way the scan does and proves it
# orders the names differently from C, so a stub that stops loading turns the
# order check red instead of letting it pass for the reason C order would.
COLLATING_LOCALE=en_US.UTF-8
FAKE_SORT="$FIXTURES/fake-locale-sort.bash"

expect_dockerfiles_sorted() {
  local dir name out status got want collated sort_err
  dir="$(mktemp -d)"
  sort_err="$(mktemp)"
  mkdir "$dir/b"
  for name in a.Dockerfile b/Dockerfile Dockerfile _.Containerfile dockerfile.dev \
    Z.Dockerfile 'a b.Dockerfile' Containerfile b.Dockerfile; do
    printf 'FROM ubuntu:24.04\n' > "$dir/$name"
  done
  # Bash warns on stderr that it cannot set a locale the host lacks, so stderr
  # is kept apart and shown only if the stub printed nothing.
  collated="$(find "$dir" -type f -print0 \
    | BASH_ENV="$FAKE_SORT" LC_ALL="$COLLATING_LOCALE" bash -c 'sort -z' 2>"$sort_err" \
    | tr '\0' '\n' | sed "s#^$dir/##")"
  out="$(HADOLINT=true BASH_ENV="$FAKE_SORT" LC_ALL="$COLLATING_LOCALE" \
    bash "$SCAN" dockerfiles "$dir" 2>&1)"
  status=$?
  rm -rf "$dir"
  got="$(printf '%s\n' "$out" | sed -n "s#^checking $dir/##p")"
  want="$(printf '%s\n' Containerfile Dockerfile Z.Dockerfile _.Containerfile \
    'a b.Dockerfile' a.Dockerfile b.Dockerfile b/Dockerfile dockerfile.dev)"
  if [ -z "$collated" ]; then
    fail "a bare sort with $(rel "$FAKE_SORT") under $COLLATING_LOCALE printed nothing, so the order check below cannot tell a bare sort from LC_ALL=C sort"
    cat "$sort_err"
  elif [ "$collated" = "$want" ]; then
    fail "a bare sort with $(rel "$FAKE_SORT") under $COLLATING_LOCALE orders the fixture names as C does, so the order check below cannot tell a bare sort from LC_ALL=C sort"
    printf '%s\n' "$collated"
  else
    pass "a bare sort with $(rel "$FAKE_SORT") under $COLLATING_LOCALE orders the fixture names differently from C"
  fi
  rm -f "$sort_err"
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -qF 'found 9 ' && [ "$got" = "$want" ]; then
    pass "Dockerfile discovery checks files in LC_ALL=C order"
  else
    fail "expected Dockerfile discovery to check its 9 files in LC_ALL=C order, exit $status"
    printf '%s\n' "$out"
  fi
}

# The same accumulator the real "Lint PHP plugins" step runs, against a fixture
# directory instead of images/plugins/. Three implementation rounds on
# ci.yml's PHP lint step each swallowed a real syntax error by way of a
# different shell/CLI exit-status quirk (a bare for-loop with no set -e, an
# -exec {} + batching misdiagnosis, and find -exec {} \; discarding a match's
# own exit status). This runs the exact prescribed pattern so a future edit
# back toward any of those shapes turns this red on the same commit.
run_php_lint_batch() {
  docker run --rm -m 1g --cpus 1 -v "$1:/plugins:ro" php:8.3-cli-alpine sh -c '
    status=0
    for f in /plugins/*.php; do
      php -l "$f" || status=1
    done
    exit "$status"
  '
}

expect_php_lint_clean() {
  local out status
  out="$(run_php_lint_batch "$1" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "$(rel "$1") lints clean"
  else
    fail "expected $(rel "$1") to lint clean, php -l batch exited $status"
    printf '%s\n' "$out"
  fi
}

# Two needles, not one: the broken file must be named as a failure, and a
# companion file elsewhere in the batch must still show its own clean result.
# A checker that stops at the first failure, or that only reports the last
# file it happened to run, passes the first needle and fails the second.
expect_php_lint_rejected() {
  local dir="$1" broken="$2" survivor="$3"
  local out status
  out="$(run_php_lint_batch "$dir" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -q "Errors parsing /plugins/$broken" \
    && printf '%s' "$out" | grep -q "No syntax errors detected in /plugins/$survivor"; then
    pass "$(rel "$dir") rejected at $broken, $survivor still checked"
  else
    fail "expected $(rel "$dir") to fail naming $broken with $survivor still checked, exit $status"
    printf '%s\n' "$out"
  fi
}

# A scan is only as good as its discovery. A discovery that dies must fail the
# scan: reported as an empty tree it goes green over files nothing looked at.
expect_scan_fails() {
  local out status
  out="$(LISTER="${3:-}" bash "$SCAN" "$1" "$2" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ]; then
    pass "scan $1 fails when discovery fails"
  else
    fail "expected scan $1 to fail when discovery fails, exit $status"
    printf '%s\n' "$out"
  fi
}

CLEANUP="$REPO_ROOT/.github/scripts/container-cleanup.sh"

# The needle includes the line number, so a fixture rejected for some other
# line than its one defect does not count.
expect_cleanup() {
  local file="$1" needle="$2" out status
  out="$(bash "$CLEANUP" "$file" 2>&1)"
  status=$?
  if [ -z "$needle" ] && [ "$status" -eq 0 ]; then
    pass "$(rel "$file") passes container-cleanup.sh"
  elif [ -n "$needle" ] && [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF "$file:$needle"; then
    pass "$(rel "$file") rejected by container-cleanup.sh at $needle"
  else
    fail "expected container-cleanup.sh on $(rel "$file") to give '${needle:-a pass}', exit $status"
    printf '%s\n' "$out"
  fi
}

# find(1) lists a directory in no fixed order, so each file opens with a run
# under the other's closing opt-out, and whichever is read second shows
# whether an opt-out carries into the next file.
expect_cleanup_carry() {
  local dir="$FIXTURES/bad/cleanup-optout-carry" out status
  out="$(bash "$CLEANUP" "$dir" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -qF "$dir/a.sh:1: a container started without --rm" \
    && printf '%s' "$out" | grep -qF "$dir/b.sh:1: a container started without --rm" \
    && printf '%s' "$out" | grep -qF "$dir/a.sh:2: a container-cleanup opt-out with no container" \
    && printf '%s' "$out" | grep -qF "$dir/b.sh:2: a container-cleanup opt-out with no container"; then
    pass "$(rel "$dir") keeps no opt-out across a file boundary"
  else
    fail "expected container-cleanup.sh on $(rel "$dir") to name both files' run and opt-out, exit $status"
    printf '%s\n' "$out"
  fi
}

# Each file ends on a continued run, so one is read before the other file
# starts and the other before the input ends, in whichever order find(1) gives.
expect_cleanup_eof_continued() {
  local dir="$FIXTURES/bad/cleanup-eof-continued" out status
  out="$(bash "$CLEANUP" "$dir" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -qF "$dir/a.sh:4: a container started without --rm" \
    && printf '%s' "$out" | grep -qF "$dir/b.sh:4: a container started without --rm"; then
    pass "$(rel "$dir") checks a run still continued when its file ends"
  else
    fail "expected container-cleanup.sh on $(rel "$dir") to name the continued run in both files, exit $status"
    printf '%s\n' "$out"
  fi
}

expect_real_cleanup() {
  local out status
  mkdir -p "$PLANTED_DIR"
  cp "$FIXTURES/bad/cleanup-rm.sh" "$PLANTED_DIR/cleanup-rm.sh"
  out="$(cd "$REPO_ROOT" && bash "$CLEANUP" 2>&1)"
  status=$?
  rm -rf "$PLANTED_DIR"
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -qF './.ci-realscan-planted/cleanup-rm.sh:5:' \
    && ! printf '%s' "$out" | grep -q 'ci-fixtures'; then
    pass "the real container-cleanup.sh invocation finds a planted file and excludes ci-fixtures"
  else
    fail "expected the real container-cleanup.sh invocation to flag the planted file and skip ci-fixtures, exit $status"
    printf '%s\n' "$out"
  fi
}

INSTALL_HADOLINT="$REPO_ROOT/.github/scripts/install-hadolint.sh"

# A stub stands in for the release asset, served over file:// so no case
# touches the network. sha256sum -c names the file it checked, which is how
# each run's download directory is read back. Every run sees an install(1)
# that refuses a destination outside this scratch directory, so a target that
# drifts to a host-wide path such as /usr/local/bin goes red here instead of
# replacing the runner's own hadolint with the stub.
expect_install_hadolint() {
  local scratch stub good_sha bad_sha want out_a out_b out_c out_d out_e
  local status_c status_d status_e dir_a dir_b dir_c
  scratch="$(mktemp -d)"
  mkdir -p "$scratch/ab" "$scratch/c" "$scratch/d" "$scratch/shim"
  printf '#!/bin/sh\nfor dest; do :; done\ncase "$dest" in %s/*) exec %s "$@" ;; esac\necho "install outside this job: $dest" >&2\nexit 1\n' \
    "$scratch" "$(command -v install)" > "$scratch/shim/install"
  chmod +x "$scratch/shim/install"
  stub="$scratch/hadolint-stub"
  printf '#!/bin/sh\necho stub\n' > "$stub"
  good_sha="$(sha256sum "$stub" | cut -d' ' -f1)"
  bad_sha="0${good_sha#?}"
  [ "$bad_sha" = "$good_sha" ] && bad_sha="1${good_sha#?}"
  run_install() {
    PATH="$scratch/shim:$PATH" RUNNER_TEMP="$scratch/$2" GITHUB_ENV="$scratch/$2.env" \
      HADOLINT_URL="file://$stub" HADOLINT_SHA256="$1" \
      bash "$INSTALL_HADOLINT" 2>&1
  }
  checked_dir() { printf '%s\n' "$1" | sed -n 's#^\(.*\)/hadolint: \(OK\|FAILED\)$#\1#p' | head -n 1; }

  out_a="$(run_install "$good_sha" ab)"
  out_b="$(run_install "$good_sha" ab)"
  out_c="$(run_install "$bad_sha" c)"
  status_c=$?
  out_d="$(env -u RUNNER_TEMP PATH="$scratch/shim:$PATH" GITHUB_ENV="$scratch/d.env" \
    HADOLINT_URL="file://$stub" HADOLINT_SHA256="$good_sha" bash "$INSTALL_HADOLINT" 2>&1)"
  status_d=$?
  out_e="$(env -u GITHUB_ENV PATH="$scratch/shim:$PATH" RUNNER_TEMP="$scratch/d" \
    HADOLINT_URL="file://$stub" HADOLINT_SHA256="$good_sha" bash "$INSTALL_HADOLINT" 2>&1)"
  status_e=$?
  dir_a="$(checked_dir "$out_a")"
  dir_b="$(checked_dir "$out_b")"
  dir_c="$(checked_dir "$out_c")"
  want="HADOLINT=$scratch/ab/bin/hadolint"

  if [ -n "$dir_a" ] && [ -n "$dir_b" ] && [ "$dir_a" != "$dir_b" ]; then
    pass "two hadolint installs download into two different directories"
  else
    fail "expected two hadolint installs to download into two different directories, got '$dir_a' and '$dir_b'"
    printf '%s\n%s\n' "$out_a" "$out_b"
  fi
  if [ "${dir_a#"$scratch/ab/hadolint."}" != "$dir_a" ] \
    && [ "${dir_b#"$scratch/ab/hadolint."}" != "$dir_b" ]; then
    pass "both hadolint downloads are in mktemp directories under RUNNER_TEMP"
  else
    fail "expected both hadolint download directories under RUNNER_TEMP, got '$dir_a' and '$dir_b'"
  fi

  if [ "$status_c" -ne 0 ] && [ -n "$dir_c" ]; then
    pass "a wrong hadolint hash fails the install at the checksum"
  else
    fail "expected a wrong hadolint hash to fail at the checksum, exit $status_c"
    printf '%s\n' "$out_c"
  fi
  if [ ! -e "$scratch/c/bin/hadolint" ] && [ ! -s "$scratch/c.env" ]; then
    pass "a wrong hadolint hash installs nothing and sets no HADOLINT"
  else
    fail "a wrong hadolint hash still installed $scratch/c/bin/hadolint or wrote $scratch/c.env"
  fi
  if cmp -s "$stub" "$scratch/ab/bin/hadolint" && [ -x "$scratch/ab/bin/hadolint" ]; then
    pass "a right hadolint hash installs the checked file, executable, at RUNNER_TEMP/bin/hadolint"
  else
    fail "expected a right hadolint hash to install the checked file, executable, at RUNNER_TEMP/bin/hadolint"
    printf '%s\n' "$out_a"
  fi
  if [ "$(grep -cxF "$want" "$scratch/ab.env" 2>/dev/null)" = 2 ] \
    && ! grep -vxF "$want" "$scratch/ab.env" >/dev/null 2>&1; then
    pass "each right-hash install points later steps at RUNNER_TEMP/bin/hadolint through GITHUB_ENV"
  else
    fail "expected GITHUB_ENV to hold exactly two '$want' lines, it holds: $(cat "$scratch/ab.env" 2>/dev/null)"
  fi
  if [ -z "$(find "$scratch/ab" "$scratch/c" -maxdepth 1 -name 'hadolint.*')" ] \
    && [ -n "$dir_a" ] && [ ! -e "$dir_a" ] && [ -n "$dir_c" ] && [ ! -e "$dir_c" ]; then
    pass "every hadolint install, right hash or wrong, removes its download directory"
  else
    fail "expected no hadolint download directory left behind: $(find "$scratch/ab" "$scratch/c" -maxdepth 1 -name 'hadolint.*')"
  fi

  if [ "$status_d" -ne 0 ] && printf '%s' "$out_d" | grep -qF RUNNER_TEMP && [ ! -e "$scratch/d.env" ]; then
    pass "with no RUNNER_TEMP, the install refuses instead of picking a shared path"
  else
    fail "expected the install to refuse with no RUNNER_TEMP, exit $status_d"
    printf '%s\n' "$out_d"
  fi
  if [ "$status_e" -ne 0 ] && printf '%s' "$out_e" | grep -qF GITHUB_ENV && [ ! -e "$scratch/d/bin" ]; then
    pass "with no GITHUB_ENV, the install refuses before installing a binary no scan would find"
  else
    fail "expected the install to refuse with no GITHUB_ENV before installing, exit $status_e"
    printf '%s\n' "$out_e"
  fi
  rm -rf "$scratch"
}

# A hadolint first on PATH that passes everything stands in for one in a
# directory any job can write. With HADOLINT unset the scan must refuse, not
# lint with it.
expect_scan_needs_hadolint() {
  local shim out status
  shim="$(mktemp -d)"
  printf '#!/bin/sh\necho PATH hadolint ran\n' > "$shim/hadolint"
  chmod +x "$shim/hadolint"
  out="$(env -u HADOLINT PATH="$shim:$PATH" bash "$SCAN" dockerfiles "$FIXTURES/bad/Dockerfile" 2>&1)"
  status=$?
  rm -rf "$shim"
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF HADOLINT \
    && ! printf '%s' "$out" | grep -qF 'PATH hadolint ran'; then
    pass "scan.sh dockerfiles with no HADOLINT refuses rather than run hadolint from PATH"
  else
    fail "expected scan.sh dockerfiles with no HADOLINT to refuse without a PATH lookup, exit $status"
    printf '%s\n' "$out"
  fi
}

# Every other dockerfiles case passes the same with a working hadolint on PATH
# as with HADOLINT, so only this one tells the two apart: each prints its own
# marker, and the lint must come from HADOLINT.
expect_scan_runs_hadolint() {
  local scratch out status
  scratch="$(mktemp -d)"
  mkdir -p "$scratch/shim"
  printf '#!/bin/sh\necho PATH hadolint ran\n' > "$scratch/shim/hadolint"
  printf '#!/bin/sh\necho HADOLINT binary ran\n' > "$scratch/checked-hadolint"
  chmod +x "$scratch/shim/hadolint" "$scratch/checked-hadolint"
  out="$(HADOLINT="$scratch/checked-hadolint" PATH="$scratch/shim:$PATH" \
    bash "$SCAN" dockerfiles "$FIXTURES/good/Dockerfile" 2>&1)"
  status=$?
  rm -rf "$scratch"
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -qF 'HADOLINT binary ran' \
    && ! printf '%s' "$out" | grep -qF 'PATH hadolint ran'; then
    pass "scan.sh dockerfiles lints with the HADOLINT binary, not a hadolint on PATH"
  else
    fail "expected scan.sh dockerfiles to run HADOLINT and never the hadolint on PATH, exit $status"
    printf '%s\n' "$out"
  fi
}

section "hadolint install, per-job, gated on the hash, found by the scans through HADOLINT"
expect_install_hadolint
expect_scan_needs_hadolint
expect_scan_runs_hadolint

section "container cleanup takes the anonymous volumes with every container"
expect_cleanup "$FIXTURES/good/cleanup.sh" ""
expect_cleanup "$FIXTURES/bad/cleanup-rm.sh" "5: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-run.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-create.sh" "4: a container created without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-container-create.sh" "4: a container created without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-dollar.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-dollar-quoted.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-dollar-twice.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-brace.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-brace-quoted.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-semicolon.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-and.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-or.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-pipe.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-background.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-nosep.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-eol.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-quoted-comment.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-argcount.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-reason.sh" "4: a container-cleanup line that is not keep <reason>"
expect_cleanup "$FIXTURES/bad/cleanup-optout-keepword.sh" "4: a container-cleanup line that is not keep <reason>"
expect_cleanup "$FIXTURES/bad/cleanup-optout-notkeep.sh" "4: a container-cleanup line that is not keep <reason>"
expect_cleanup "$FIXTURES/bad/cleanup-optout-nospace.sh" "4: a container-cleanup line that is not keep <reason>"
expect_cleanup "$FIXTURES/bad/cleanup-optout-eof.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-twice.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-comment.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-comment.sh" "6: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-command.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-command.sh" "6: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-sameline.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-sameline.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-two-commands.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-rm.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-rm.sh" "5: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-optout-after-rm.sh" "4: a container-cleanup opt-out with no container under it to keep"
expect_cleanup "$FIXTURES/bad/cleanup-optout-after-rm.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-inline.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-optout-unspaced.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-continued-hash.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-tab.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-unspaced.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-rm.sh" "4: a container removed without -v"
expect_cleanup "$FIXTURES/bad/cleanup-comment-paren.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-twice.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-comment-continued.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-continued-comment.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-length.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-strip.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-single.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-escaped.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-blank.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-subshell.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-multiline.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-continued.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-heredoc.sh" "7: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-apostrophe.sh" "7: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-apostrophe-quoted.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-dquote-in-single.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-url.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-dquote.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-ansi.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-in-flag.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-comment-run.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-in-word.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-in-word.sh" "6: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-hash-in-word.sh" "7: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-image-rm.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "6: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "7: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "8: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "9: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "10: a container created without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-after-image.sh" "11: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-quoted-value.sh" "4: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-quoted-value.sh" "5: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-quoted-value.sh" "6: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-quoted-value.sh" "7: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-quoted-value.sh" "8: a container started without --rm"
expect_cleanup "$FIXTURES/bad/cleanup-rm-quoted-value.sh" "9: a container started without --rm"
expect_cleanup_carry
expect_cleanup_eof_continued
expect_real_cleanup

section "hadolint, through scan.sh's own check_dockerfiles"
expect_scan_ok dockerfiles "$FIXTURES/good/Dockerfile"
expect_scan_bad dockerfiles "$FIXTURES/bad/Dockerfile" DL3007

section "hadolint reaches Containerfile, not only Dockerfile"
expect_scan_ok dockerfiles "$FIXTURES/good/Containerfile"
expect_scan_bad dockerfiles "$FIXTURES/bad/Containerfile" DL3007

section "hadolint reaches a name in any case"
expect_scan_bad dockerfiles "$FIXTURES/bad/lowercase/dockerfile" DL3007
expect_scan_bad dockerfiles "$FIXTURES/bad/lowercase/containerfile" DL3007

section "Dockerfile discovery, every dotted name form found, near misses skipped"
expect_dockerfile_found Dockerfile.dev
expect_dockerfile_found app.Dockerfile
expect_dockerfile_found Containerfile.dev
expect_dockerfile_found app.Containerfile
expect_dockerfile_found dockerfile.dev
expect_dockerfile_found app.dockerfile
expect_dockerfile_found containerfile.dev
expect_dockerfile_found app.CONTAINERFILE
expect_dockerfile_found dockerfile
expect_dockerfile_skipped MyDockerfile
expect_dockerfile_skipped Dockerfile_old
expect_dockerfile_found containerfile
expect_dockerfile_skipped AppContainerfile
expect_dockerfile_skipped Containerfile_old

section "Dockerfile discovery reports in LC_ALL=C order, as compose discovery does"
expect_dockerfiles_sorted

section "compose discovery, by content and not by filename"
expect_listed "$FIXTURES/good" compose.yaml
expect_listed "$FIXTURES/good" stack.yaml
expect_not_listed "$FIXTURES/good" rollout.yml
expect_listed "$FIXTURES/good" uppercase-extension.YAML
expect_listed "$FIXTURES/good" uppercase-extension.YML

section "compose validation, through scan.sh's own check_compose"
expect_scan_ok compose "$FIXTURES/good/compose.yaml"
expect_scan_ok compose "$FIXTURES/good/stack.yaml"
expect_scan_ok compose "$FIXTURES/good/uppercase-extension.YAML"
expect_scan_bad compose "$FIXTURES/bad/schema.compose.yaml" ports
expect_scan_bad compose "$FIXTURES/bad/unparseable.compose.yml" yaml

section "php lint, broken file at each position in a multi-file batch"
expect_php_lint_clean "$FIXTURES/good/php-plugins"
expect_php_lint_rejected "$FIXTURES/bad/php-plugins-first" a_broken.php z_valid.php
expect_php_lint_rejected "$FIXTURES/bad/php-plugins-middle" m_broken.php z_valid.php
expect_php_lint_rejected "$FIXTURES/bad/php-plugins-last" z_broken.php a_valid.php

section "a failed discovery fails the scan, it does not read as an empty tree"
expect_scan_fails dockerfiles "$REPO_ROOT/no-such-tree"
expect_scan_fails compose "$FIXTURES/good" "$REPO_ROOT/no-such-lister.sh"

section "the exact invocation ci.yml uses: a kind, no root, no prune argument"
expect_real_scan dockerfiles "$FIXTURES/bad/Dockerfile"
expect_real_scan compose "$FIXTURES/bad/schema.compose.yaml"

PINS="$REPO_ROOT/.github/scripts/action-pins.sh"
PIN_WORKFLOWS="$FIXTURES/bad/action-pins/.github/workflows"

# The checked count is asserted because a good file passes just as well when
# the check stops recognising a uses: line at all.
expect_pins_clean() {
  local file="$1" count="$2" out status
  out="$(bash "$PINS" "$file" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -qF 'found 1 ' \
    && printf '%s' "$out" | grep -qxF "checked $count uses: line(s)"; then
    pass "$(rel "$file") passes action-pins.sh with $count uses: lines checked"
  else
    fail "expected $(rel "$file") to pass action-pins.sh with $count uses: lines checked, exit $status"
    printf '%s\n' "$out"
  fi
}

# Exactly one line reported, and it is the fixture's one defect.
expect_pins_bad() {
  local file="$1" line="$2" out status
  out="$(bash "$PINS" "$file" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF "$file:$line: " \
    && [ "$(printf '%s\n' "$out" | grep -c ': an action not pinned')" = 1 ]; then
    pass "$(rel "$file") rejected by action-pins.sh at line $line only"
  else
    fail "expected action-pins.sh to reject $(rel "$file") at line $line and nowhere else, exit $status"
    printf '%s\n' "$out"
  fi
}

expect_real_pins() {
  local planted="$PLANTED_DIR/.github/workflows" out status
  mkdir -p "$planted"
  cp "$PIN_WORKFLOWS/tag.yml" "$planted/tag.yml"
  out="$(cd "$REPO_ROOT" && bash "$PINS" 2>&1)"
  status=$?
  rm -rf "$PLANTED_DIR"
  if [ "$status" -ne 0 ] \
    && printf '%s' "$out" | grep -qF './.ci-realscan-planted/.github/workflows/tag.yml:8: ' \
    && ! printf '%s' "$out" | grep -q 'ci-fixtures'; then
    pass "the real action-pins.sh invocation finds a planted workflow and excludes ci-fixtures"
  else
    fail "expected the real action-pins.sh invocation to flag the planted workflow and skip ci-fixtures, exit $status"
    printf '%s\n' "$out"
  fi
}

section "every uses: names a commit sha, a local path or an image digest"
expect_pins_clean "$FIXTURES/good/action-pins/.github/workflows/pinned.yml" 11
expect_pins_bad "$PIN_WORKFLOWS/tag.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/short-sha.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/long-sha.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/uppercase-sha.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/double-quoted-tag.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/single-quoted-tag.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/sha-in-comment.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/trailing-word.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/url.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/no-ref.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/docker-tag.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/spaced-key.yml" 9
expect_pins_bad "$PIN_WORKFLOWS/reusable-branch.yml" 10
expect_pins_bad "$PIN_WORKFLOWS/flow-mapping.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/flow-mapping-line-start.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/double-quoted-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/single-quoted-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/flow-sequence.yml" 7
expect_pins_bad "$PIN_WORKFLOWS/flow-quoted-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/explicit-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/tagged-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/anchored-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/escaped-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/nested-sequence.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/alias-key.yml" 10
expect_pins_bad "$PIN_WORKFLOWS/flow-tagged-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/tagged-quoted-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/flow-explicit-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/flow-alias-key.yml" 10
expect_pins_bad "$PIN_WORKFLOWS/flow-anchored-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/flow-tagged-anchored-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/flow-sequence-explicit-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/comma-explicit-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/tagged-single-quoted-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/flow-sequence-alias-key.yml" 10
expect_pins_bad "$PIN_WORKFLOWS/comma-alias-key.yml" 10
expect_pins_bad "$PIN_WORKFLOWS/alias-key-value-next-line.yml" 10
expect_pins_bad "$PIN_WORKFLOWS/flow-unspaced-explicit-key.yml" 8
expect_pins_bad "$PIN_WORKFLOWS/flow-unspaced-explicit-alias-key.yml" 10
expect_pins_bad "$PIN_WORKFLOWS/column-zero-alias-key.yml" 7
expect_pins_bad "$FIXTURES/bad/action-pins/composite/action.yml" 8
expect_real_pins

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed. A check has stopped discriminating.\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed, both sides for hadolint, discovery, compose, php lint, container cleanup and action pins.\n' "$PASSES"
printf 'scan.sh itself is exercised end to end: discovery, both check functions, the loop, and the exact no-argument invocation ci.yml uses.\n'
