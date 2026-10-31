#!/usr/bin/env bash
# Proves bot-proofs-finish.sh can fail (riftal-infra#1316, #1317). Fixture hold logs,
# runner logs, record files and a fake process-state root drive its functions, then
# each mutant of it must fail exactly the cases that guard the line it breaks. The
# harness is not run, no container starts.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINISH="$DIR/bot-proofs-finish.sh"
EXPECTED_CASES=74

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# $1 the file to source, $2 a scratch directory of its own. Prints one "  ok" or
# "FAILCASE" line per case, so a mutant that stops early shows as missing cases.
run_cases() { ( . "$1" && cases "$2" ); }

cases() {
  local d=$1 probe="$1/probe.js" dt="$1/devtools" good pair written no="$1/absent" ok lf
  mkdir -p "$d/proc"
  PROC_ROOT="$d/proc"
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
    read_hold_log "$4"; read_records "$5" "$d/hold.log" "$d/a.log"
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

  # Pid 101 is a zombie, 102 is gone, 103 sleeps and 104 has no readable state.
  mkdir -p "$d/proc/101" "$d/proc/103" "$d/proc/104"
  printf 'State:\tZ (zombie)\n' >"$d/proc/101/status"
  printf 'State:\tS (sleeping)\n' >"$d/proc/103/status"
  ok="$d/run.ok"
  printf '%s\n' 'SOCKET LISTING s | pid 7 | live bots 1 | clean | one socket' \
    'PROBE HOLD 1 {"pid":7,"port":411,"sockets":[{"port":411}],"liveBots":1}' \
    'ROOT LISTING 1 clean | held port 411 | no finding' 'PROBE RELEASED 1 411 open' \
    'PROBE DONE {"holds":1,"ports":[411]}' 'SCENARIO PASS s | ok' >"$ok"
  cp "$ok" "$d/hold.log"
  cp "$ok" "$d/a.log"
  printf '%s\n' 'PROBE DONE {"holds":0,"ports":[]}' 'SCENARIO FAIL s | no hold' >"$d/run.zero"
  # $1 id, then pid and log pairs; prints the record file
  recs() {
    local f="$d/recs.$1"
    shift; : >"$f"
    while [ "$#" -ge 2 ]; do printf 'node\t%s\t%s\n' "$1" "$2" >>"$f"; shift 2; done
    printf '%s' "$f"
  }
  # $1 id, $2 wanted status, $3 body rc, $4 hold log, then pid and log pairs
  run_is() { local id=$1 want=$2 rc=$3 hold=$4; shift 4; status_is "$id" "$want" "$rc" "$hold" "$(recs "$id" "$@")"; }
  # $1 id, $2 a sed script, $3 the log it edits, the clean runner log by default; prints the copy
  var() { sed "$2" "${3:-$ok}" >"$d/run.$1"; printf '%s' "$d/run.$1"; }

  run_is run-clean 4 1 "$good" 101 "$ok"
  run_is run-reaped 4 1 "$good" 102 "$ok"
  run_is run-zero-holds 4 1 "$good" 101 "$d/run.zero"
  run_is run-two-clean 4 1 "$good" 101 "$ok" 102 "$(var two 's/PASS s/PASS t/')"
  run_is run-live 1 1 "$good" 103 "$ok"
  run_is run-state-unreadable 1 1 "$good" 104 "$ok"
  run_is run-no-log 1 1 "$good" 101 -
  run_is duplicate-log 1 1 "$good" 101 "$ok" 102 "$ok"
  run_is log-is-hold-log 1 1 "$good" 101 "$d/hold.log"
  run_is log-is-harness-log 1 1 "$good" 101 "$d/a.log"
  run_is scenario-none 1 1 "$good" 101 "$(var s0 '/^SCENARIO/d')"
  run_is scenario-twice 1 1 "$good" 101 "$(var s2 '$a SCENARIO FAIL s | again')"
  run_is scenario-verdict 1 1 "$good" 101 "$(var sv 's/^SCENARIO PASS/SCENARIO BLOCKED/')"
  run_is scenario-timed-out 1 1 "$good" 101 "$(var st 's/| ok/| timed out/')"
  run_is done-none 1 1 "$good" 101 "$(var d0 '/^PROBE DONE/d')"
  run_is done-twice 1 1 "$good" 101 "$(var d2 '/^PROBE DONE/p')"
  run_is hold-count 1 1 "$good" 101 "$(var hc '/^PROBE HOLD/d')"
  run_is root-void 1 1 "$good" 101 "$(var rv 's/^ROOT LISTING 1 clean/ROOT LISTING 1 void/')"
  run_is root-extra 1 1 "$good" 101 "$(var re '$a ROOT LISTING 2 void | held port 412 | x')"
  run_is release-closed 1 1 "$good" 101 "$(var rc 's/ open$/ closed/')"
  run_is release-missing 1 1 "$good" 101 "$(var rm '/^PROBE RELEASED/d')"
  run_is release-extra 1 1 "$good" 101 "$(var rx '$a PROBE RELEASED 2 412 open')"
  run_is release-port 1 1 "$good" 101 "$(var rp 's/^PROBE RELEASED 1 411/PROBE RELEASED 1 412/')"
  run_is ports-unheld 1 1 "$good" 101 "$(var pu 's/\[411\]/[411,999]/')"
  run_is socket-void 1 1 "$good" 101 "$(var sk 's/| clean | one/| void | one/')"
  run_is socket-recorded-only 1 1 "$good" 101 "$(var so 's/| clean | one/| clean (recorded only, raknet-native) | one/')"
  run_is zero-holds-socket 1 1 "$good" 101 "$(var zs '1i SOCKET LISTING s | pid 7 | live bots 1 | clean | x' "$d/run.zero")"
  run_is zero-holds-ports 1 1 "$good" 101 "$(var zp 's/\[\]/[411]/' "$d/run.zero")"
  for pair in 2:2 3:1 4:1 124:124; do run_is "run-rc${pair%:*}" "${pair#*:}" "${pair%:*}" "$good" 101 "$ok"; done
  run_is run-pass-clean 0 0 "$good" 101 "$ok"
  run_is run-pass-unclean 1 0 "$good" 101 -

  # Run 39689157070: the hold log, then the runner's two lines.
  cat >"$d/hold.real" <<'LOG'
RUNNER pid=2354402 port=59652
RUNNER LISTING clean: 1 socket(s) on 127.0.0.1 for 1 live bot(s)
ROOT LISTING 1 clean | held port 59652 | no finding
  State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
  UNCONN 0      0         127.0.0.54:53         0.0.0.0:*     users:(("systemd-resolve",pid=81,fd=18))
  UNCONN 0      0      127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=81,fd=16))
  UNCONN 0      0          127.0.0.1:33005      0.0.0.0:*     users:(("docker-proxy",pid=2354286,fd=7))
  UNCONN 0      0          127.0.0.1:323        0.0.0.0:*     users:(("chronyd",pid=224,fd=4))
  UNCONN 0      0          127.0.0.1:323        0.0.0.0:*
  UNCONN 0      0          127.0.0.1:59652      0.0.0.0:*     users:(("MainThread",pid=2354402,fd=21))
  ESTAB  0      0         172.18.0.1:36324   172.18.0.3:19132 users:(("docker-proxy",pid=2354286,fd=3))
  UNCONN 0      0              [::1]:323           [::]:*
  UNCONN 0      0              [::1]:323           [::]:*     users:(("chronyd",pid=224,fd=5))
  #cmdlines
  2354286 /usr/bin/docker-proxy -proto udp -host-ip 127.0.0.1 -host-port 33005 -container-ip 172.18.0.3 -container-port 19132 -use-listen-fd
probed 1
PROBE RELEASED 1 59652 open
LOG
  printf '%s\n' 'PROBE DONE {"holds":0,"ports":[]}' \
    'SCENARIO FAIL capture-stall-drop-pickup | ADR 024 root listing not clean: the runner opened no hold | missing .../canonical_block_states.nbt; run: node devtools/fetch-palette.js' >"$d/run.real"
  run_is real-run 4 1 "$d/hold.real" 101 "$d/run.real"

  # $1 id, $2 the log field wanted, $3 and $4 what fd 1 and fd 2 link to, $5 and $6
  # their offsets once a line was written to fd 1
  fd_is() {
    local p="$d/proc/$$"
    rm -rf "$p"; mkdir -p "$p/fd" "$p/fdinfo"
    ln -s "$3" "$p/fd/1"; ln -s "$4" "$p/fd/2"
    printf 'pos:\t%s\n' "$5" >"$p/fdinfo/1"; printf 'pos:\t%s\n' "$6" >"$p/fdinfo/2"
    record_node_start "$probe" "$d/rec.$1" "$dt/run-scenario.js" >/dev/null
    is "$1" "$2" "$(cut -f3 "$d/rec.$1")"
  }
  lf="$d/log.f"; : >"$lf"; : >"$d/log.g"
  fd_is fd-one-description "$lf" "$lf" "$lf" 9 9
  fd_is fd-two-descriptions - "$lf" "$lf" 9 0
  fd_is fd-no-line-written - "$lf" "$lf" 0 0
  fd_is fd-two-files - "$lf" "$d/log.g" 9 9
  fd_is fd-pipe - 'pipe:[7]' 'pipe:[7]' 9 9
  fd_is fd-dev-null - /dev/null /dev/null 9 9
  rm -rf "$d/proc/$$"

  FOUND=1 LISTINGS=1 LISTINGS_CLEAN=1 HOLDS=1 RELEASED=1 HOLD_FAILURES=0 RUNNERS=0 RUNNERS_CLEAN=0
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
recorded="record-run-scenario record-unlisted record-no-slash record-other-probe"
unclean="run-live run-state-unreadable run-no-log duplicate-log log-is-hold-log log-is-harness-log scenario-none scenario-twice scenario-verdict scenario-timed-out done-none done-twice hold-count root-void root-extra release-closed release-missing release-extra release-port ports-unheld socket-void socket-recorded-only zero-holds-socket zero-holds-ports"
mutant rule-without-clean-finish "&& clean_finish; then" "; then" \
  "no-hold-log no-listing void-listing closed-release hold-failure $recorded $unclean run-pass-unclean"
mutant rule-any-status "$rule" '[ "$status" != 0 ] && clean_finish' "rc2 rc3 rc4 rc124 rc125 rc127 rc130 run-rc2 run-rc3 run-rc4 run-rc124"
mutant rc-set-to-4 '{ [ "$rc" = 0 ] || [ "$rc" = 1 ]; }' '[ "$rc" -le 4 ]' "rc3 rc4 run-rc3 run-rc4"
mutant rc-set-to-0 '{ [ "$rc" = 0 ] || [ "$rc" = 1 ]; }' '[ "$rc" = 0 ]' "rc1 exempt-starts-only run-clean run-reaped run-zero-holds run-two-clean real-run"
mutant rc-set-to-1 '{ [ "$rc" = 0 ] || [ "$rc" = 1 ]; }' '[ "$rc" = 1 ]' "failed-assertion short-count"
mutant found-unchecked '[ "$FOUND" = 0 ] && ' '' "clean-found"
mutant listing-not-needed '[ "$LISTINGS" -ge 1 ]' '[ "$LISTINGS" -ge 0 ]' "no-hold-log no-listing"
mutant listing-not-clean '[ "$LISTINGS" = "$LISTINGS_CLEAN" ]' 'true' "void-listing"
mutant hold-not-released '[ "$HOLDS" = "$RELEASED" ]' 'true' "closed-release"
mutant hold-failure-ignored '[ "$HOLD_FAILURES" = 0 ]' 'true' "hold-failure"
mutant runners-ignored '[ "$RUNNERS" = "$RUNNERS_CLEAN" ]' 'true' "$recorded $unclean run-pass-unclean"
mutant status-0-unclean-ignored '[ "$RUNNERS" != "$RUNNERS_CLEAN" ]; then' 'false; then' "run-pass-unclean"
mutant runner-still-live 'runner_exited "${pids[i]}" && ' '' "run-live run-state-unreadable"
mutant unreadable-state-exited '[ "$state" = Z ] || [ "$state" = X ]' '[ "$state" != S ]' "run-state-unreadable"
mutant gone-process-live '[ -d "$PROC_ROOT/$1" ] || return 0' '[ -d "$PROC_ROOT/$1" ] || return 1' "run-reaped run-two-clean"
mutant duplicate-log-allowed '[ "$j" -ne "$i" ] && ' 'false && ' "duplicate-log"
mutant every-log-duplicates-itself '[ "$j" -ne "$i" ] && ' '' "run-clean run-reaped run-zero-holds run-two-clean run-pass-clean real-run"
mutant harness-file-allowed '[ "${logs[i]}" -ef "$f" ] && continue 2' 'false' "log-is-hold-log log-is-harness-log"
mutant scenario-count-ignored 'sc != 1 || ' '' "scenario-none scenario-twice"
mutant scenario-verdict-ignored '$0 !~ /^SCENARIO (PASS|FAIL|INCONCLUSIVE) / || ' '' "scenario-verdict"
mutant timed-out-ignored ' || $0 ~ /timed out/' '' "scenario-timed-out"
mutant done-count-ignored 'dn != 1 || ' '' "done-twice"
mutant hold-count-ignored 'holds + 0 != h || ' '' "hold-count"
mutant root-count-ignored 'rl + 0 != h || ' '' "root-extra"
mutant release-count-ignored 'rel + 0 != h || ' '' "release-extra"
mutant hold-pairs-ignored 'if (!(n in held) || !(n in opened) || held[n] != opened[n]) exit 1' 'if (0) exit 1' "release-closed release-port"
mutant ports-ignored 'if (!(ps[i] in known)) exit 1' 'if (0) exit 1' "ports-unheld zero-holds-ports"
mutant socket-verdict-ignored 'live bots [0-9]+ \| clean \|/) bad = 1' 'live bots [0-9]+ \| [a-z]+/) bad = 1' "socket-void socket-recorded-only"
mutant zero-holds-sockets-ignored ' || (h == 0 && sk > 0)' '' "zero-holds-socket"
mutant unshared-recorded-as-shared 'shared_log || LOG_PATH=-' 'shared_log || true' "fd-two-descriptions fd-no-line-written fd-two-files fd-pipe fd-dev-null"
mutant offsets-ignored ' && $p1 = "$p2" ]]' ' ]]' "fd-two-descriptions"
mutant zero-offset-allowed '^[1-9][0-9]*$' '^[0-9]+$' "fd-no-line-written"
mutant fd-paths-ignored ' && $LOG_PATH == "$(readlink "$fd/fd/2")"' '' "fd-two-files"
mutant regular-file-ignored ' && -f $LOG_PATH' '' "fd-dev-null"
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
