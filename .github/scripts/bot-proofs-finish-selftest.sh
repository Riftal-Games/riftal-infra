#!/usr/bin/env bash
# Proves bot-proofs-finish.sh can fail (riftal-infra#1316). Fixture hold logs and
# record files drive its functions, then each mutant of it must fail exactly the
# cases that guard the line it breaks. The harness is not run, no container starts.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINISH="$DIR/bot-proofs-finish.sh"
EXPECTED_CASES=33

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 the file to source, $2 a scratch directory of its own. Prints one "  ok" or
# "FAILCASE" line per case, so a mutant that stops early shows as missing cases.
run_cases() { ( . "$1" && cases "$2" ); }

cases() {
  local d=$1 probe="$1/probe.js" dt="$1/devtools" good pair written no="$1/absent"
  mkdir -p "$d"
  good="$d/hold.good"
  printf '%s\n' 'RUNNER pid=2354402 port=59652' \
    'RUNNER LISTING clean: 1 socket(s) on 127.0.0.1 for 1 live bot(s)' \
    'ROOT LISTING 1 clean | held port 59652 | no finding' 'probed 1' \
    'PROBE RELEASED 1 59652 open' >"$good"
  sed 's/^ROOT LISTING 1 clean/ROOT LISTING 1 void/' "$good" >"$d/hold.void"
  sed 's/ open$/ closed/' "$good" >"$d/hold.closed"
  grep -v '^ROOT LISTING' "$good" >"$d/hold.none"
  { cat "$good"; echo 'HOLD FAILURE hold 1 released closed'; } >"$d/hold.failure"

  # $1 id, $2 wanted, $3 got
  is() {
    if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; else printf 'FAILCASE %s wanted "%s", got "%s"\n' "$1" "$2" "$3"; fi
  }
  # $1 id, then the argument list of one "$NODE" start; prints the record file
  rec() { local f="$d/rec.$1"; shift; record_node_start "$probe" "$f" "$@"; printf '%s' "$f"; }
  # $1 id, $2 wanted status, $3 body rc, $4 hold log, $5 record file, then VAR=value
  status_is() {
    local id=$1 want=$2 rc=$3 kv
    FOUND=0 PASSES=13 FAILURES=0 EXPECTED_ASSERTIONS=13
    read_hold_log "$4"; read_records "$5"
    shift 5
    for kv; do printf -v "${kv%%=*}" %s "${kv#*=}"; done
    is "$id" "$want" "$(finish_status "$rc" 2>/dev/null)"
  }

  for pair in 2:2 3:1 4:1 124:124 125:125 127:127 130:130; do
    status_is "rc${pair%:*}" "${pair#*:}" "${pair%:*}" "$good" "$no"
  done
  status_is pass-all 0 0 "$good" "$no"
  status_is failed-assertion 4 0 "$good" "$no" PASSES=12 FAILURES=1
  status_is short-count 4 0 "$good" "$no" PASSES=12
  status_is rc1 4 1 "$good" "$no"
  status_is found 3 1 "$good" "$no" FOUND=1
  status_is no-hold-log 1 1 "$no" "$no"
  status_is no-listing 1 1 "$d/hold.none" "$no"
  status_is void-listing 1 1 "$d/hold.void" "$no"
  status_is closed-release 1 1 "$d/hold.closed" "$no"
  status_is hold-failure 1 1 "$d/hold.failure" "$no"

  rec exempt "$probe" hold >/dev/null
  rec exempt "$probe" ping 33005 >/dev/null
  rec exempt --version >/dev/null
  status_is exempt-starts-only 4 1 "$good" "$d/rec.exempt"
  status_is record-run-scenario 1 1 "$good" "$(rec scenario "$dt/run-scenario.js" s --engine docker)"
  status_is record-unlisted 1 1 "$good" "$(rec unlisted "$dt/fetch-palette.js")"
  status_is record-no-slash 1 1 "$good" "$(rec bare run-scenario.js s)"
  status_is record-other-probe 1 1 "$good" "$(rec other /elsewhere/probe.js hold)"

  FOUND=1 LISTINGS=1 LISTINGS_CLEAN=1 HOLDS=1 RELEASED=1 HOLD_FAILURES=0 RUNNERS=0
  is clean-found false "$(clean_finish && echo true || echo false)"

  # $1 id, $2 wanted RUNNERS, $3 record file
  records_is() { read_records "$3"; is "$1" "$2" "$RUNNERS"; }
  records_is no-file 0 "$no"
  records_is probe-start 0 "$d/rec.exempt"
  records_is scenario-start 1 "$d/rec.scenario"
  records_is version-extra 1 "$(rec vx --version extra)"
  records_is probe-not-first 1 "$(rec pnf --flag "$probe")"
  records_is no-arguments 1 "$(rec none)"
  records_is probe-prefix 1 "$(rec pp "$probe.bak" hold)"
  records_is version-prefix 1 "$(rec vp --versionx)"
  rec two a.js >/dev/null
  records_is two-starts 2 "$(rec two b.js)"
  written=0
  record_node_start "$probe" "$d" "$dt/run-scenario.js" 2>/dev/null || written=$?
  is write-fails true "$([ "$written" -ne 0 ] && echo true || echo false)"
}

out="$(run_cases "$FINISH" "$work/real")"
printf '%s\n' "$out"
shown=$(grep -cE '^(  ok|FAILCASE) ' <<<"$out")
if grep -q '^FAILCASE ' <<<"$out" || [ "$shown" -ne "$EXPECTED_CASES" ]; then
  printf '::error::%s of %s cases ran, with failures above if any\n' "$shown" "$EXPECTED_CASES"
  exit 1
fi

src="$(cat "$FINISH")"
FAILURES=0 PASSES=0
# $1 id, $2 text of bot-proofs-finish.sh to replace, $3 its replacement, $4 the ids
# of the cases that must fail, in order, and no others
mutant() {
  local file="$work/mutant.$1.sh" mutated="${src/"$2"/"$3"}" got
  if [ "$mutated" = "$src" ]; then
    printf '::error::mutant %s did not apply\n' "$1"; FAILURES=$((FAILURES + 1)); return
  fi
  printf '%s\n' "$mutated" >"$file"
  out="$(run_cases "$file" "$work/m.$1" 2>&1)"
  got="$(sed -n 's/^FAILCASE \([^ ]*\) .*/\1/p' <<<"$out" | tr '\n' ' ')"
  shown=$(grep -cE '^(  ok|FAILCASE) ' <<<"$out")
  if [ "${got% }" = "$4" ] && [ "$shown" -eq "$EXPECTED_CASES" ]; then
    printf '  ok    mutant %s fails: %s\n' "$1" "$4"; PASSES=$((PASSES + 1))
  else
    printf '::error::mutant %s failed "%s" of %s cases, wanted "%s"\n' "$1" "${got% }" "$shown" "$4"; FAILURES=$((FAILURES + 1))
  fi
}

rule='[ "$status" = 1 ] && { [ "$rc" = 0 ] || [ "$rc" = 1 ]; } && clean_finish'
mutant rule-without-clean-finish "&& clean_finish; then" "; then" \
  "no-hold-log no-listing void-listing closed-release hold-failure record-run-scenario record-unlisted record-no-slash record-other-probe"
mutant rule-any-status "$rule" '[ "$status" != 0 ] && clean_finish' "rc2 rc3 rc4 rc124 rc125 rc127 rc130"
mutant rc-set-to-4 '{ [ "$rc" = 0 ] || [ "$rc" = 1 ]; }' '[ "$rc" -le 4 ]' "rc3 rc4"
mutant rc-set-to-0 '{ [ "$rc" = 0 ] || [ "$rc" = 1 ]; }' '[ "$rc" = 0 ]' "rc1 exempt-starts-only"
mutant rc-set-to-1 '{ [ "$rc" = 0 ] || [ "$rc" = 1 ]; }' '[ "$rc" = 1 ]' "failed-assertion short-count"
mutant found-unchecked '[ "$FOUND" = 0 ] && ' '' "clean-found"
mutant listing-not-needed '[ "$LISTINGS" -ge 1 ]' '[ "$LISTINGS" -ge 0 ]' "no-hold-log no-listing"
mutant listing-not-clean '[ "$LISTINGS" = "$LISTINGS_CLEAN" ]' 'true' "void-listing"
mutant hold-not-released '[ "$HOLDS" = "$RELEASED" ]' 'true' "closed-release"
mutant hold-failure-ignored '[ "$HOLD_FAILURES" = 0 ]' 'true' "hold-failure"
mutant record-ignored '[ "$RUNNERS" = 0 ]' 'true' "record-run-scenario record-unlisted record-no-slash record-other-probe"
mutant probe-start-recorded '[ -n "$probe" ] && [ "$#" -ge 1 ] && [ "$1" = "$probe" ]' 'false' "exempt-starts-only probe-start"
mutant probe-any-path '[ "$1" = "$probe" ]' '[[ $1 == */probe.js ]]' "record-other-probe"
mutant probe-any-position '[ "$#" -ge 1 ] && [ "$1" = "$probe" ]' '[[ " $* " == *" $probe "* ]]' "probe-not-first"
mutant probe-prefix-match '[ "$1" = "$probe" ]' '[[ $1 == "$probe"* ]]' "probe-prefix"
mutant version-prefix-match '[ "$1" = --version ]' '[[ $1 == --version* ]]' "version-prefix"
mutant version-start-recorded '[ "$#" -eq 1 ] && [ "$1" = --version ]' 'false' "exempt-starts-only probe-start"
mutant version-with-arguments '[ "$#" -eq 1 ] && [ "$1" = --version ]' '[ "${1-}" = --version ]' "version-extra"
mutant write-failure-ignored '>>"$file"' '>>"$file" || true' "write-fails"

if [ "$FAILURES" -ne 0 ]; then
  printf '%s mutant(s) not caught for the reason expected\n' "$FAILURES"
  exit 1
fi
printf 'bot-proofs-finish.sh refuses every mutant for its own reason (%s cases, %s mutants)\n' "$EXPECTED_CASES" "$PASSES"
