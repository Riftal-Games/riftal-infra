#!/usr/bin/env bash
# Self-test for custody-alert-act.sh. A stub docker and a stub curl sit first
# on PATH and record every call, so no container is touched and nothing
# reaches the network. The real custody-alert-check.sh reads fixture logs.
# CUSTODY_ACT names another copy of the script to test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACT="${CUSTODY_ACT:-$SCRIPT_DIR/custody-alert-act.sh}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"
CALLS="$DIR/calls"
mkdir "$BIN"
fake_url='https://discord.invalid/api/webhooks/0/not-a-real-token'

cat >"$BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS/docker.log"
[ -z "${FAKE_DOCKER_FAIL:-}" ] || exit 1
EOF
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS/curl.args"
cat >>"$CALLS/curl.stdin"
prev=''
for a in "$@"; do
  [ "$prev" != --data-binary ] || cat "${a#@}" >>"$CALLS/curl.body"
  prev="$a"
done
exit "${FAKE_CURL_EXIT:-0}"
EOF
chmod +x "$BIN/docker" "$BIN/curl"

boot='[11:59:59.000] [Server thread/INFO]: Loading server configuration'
e='[Server thread/EMERGENCY]: [RiftalCustody]'
printf '%s\n' "$boot" >"$DIR/quiet.log"
printf '%s\n%s\n' "$boot" "$e flushing Steve failed at file fsync and the probe failed too, so no player file can be made durable; killing the process" >"$DIR/probe.log"
printf '%s\n%s\n' "$boot" "$e RiftalCustody was disabled while the server is running; killing the process so no world saves without it" >"$DIR/disabled.log"
printf '%s\n%s\n' "$boot" "$e say \"hi\" \\ there" >"$DIR/quoted.log"

failures=0
ran=0
expected=11
out=''
got=0
# run_case <exit> <case> [VAR=value ...] -- <container> [<log> ...]
run_case() {
  local want="$1" name="$2" envs=()
  shift 2
  while [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  rm -rf "$CALLS"
  mkdir "$CALLS"
  ran=$((ran + 1))
  set +e
  out="$(cd "$DIR" && env -u CUSTODY_WEBHOOK_URL ${envs[@]+"${envs[@]}"} CALLS="$CALLS" PATH="$BIN:$PATH" bash "$ACT" "$@" 2>&1)"
  got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    printf 'FAIL %s: want exit %s, got %s:\n%s\n' "$name" "$want" "$got" "$out"
    failures=$((failures + 1))
    return 1
  fi
}
# has <case> <file> <fixed text>: a recorded call or body holds the text.
has() {
  if ! grep -q -F -- "$3" "$CALLS/$2" 2>/dev/null; then
    printf 'FAIL %s: %s lacks %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}
# lacks <case> <file> <fixed text>: the file holds no such text, or is absent.
lacks() {
  if grep -q -F -- "$3" "$CALLS/$2" 2>/dev/null; then
    printf 'FAIL %s: %s holds %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}
# silent <case> <file>: the stub was never called.
silent() {
  if [ -e "$CALLS/$2" ]; then
    printf 'FAIL %s: %s was called:\n%s\n' "$1" "$2" "$(cat "$CALLS/$2")"
    failures=$((failures + 1))
  fi
}
# out_has <case> <fixed text>: the script's own output holds the text.
out_has() {
  if ! grep -q -F -- "$2" <<<"$out"; then
    printf 'FAIL %s: output lacks %s:\n%s\n' "$1" "$2" "$out"
    failures=$((failures + 1))
  fi
}
no_url_leak() {
  lacks "$1" curl.args "$fake_url"
  lacks "$1" curl.body "$fake_url"
  if grep -q -F -- "$fake_url" <<<"$out"; then
    printf 'FAIL %s: output holds the webhook URL\n' "$1"
    failures=$((failures + 1))
  fi
}
parked() {
  has "$1" docker.log 'update --restart=no prod-a'
  has "$1" docker.log 'stop -t 60 prod-a'
  if [ "$(head -n 1 "$CALLS/docker.log" 2>/dev/null)" != 'update --restart=no prod-a' ]; then
    printf 'FAIL %s: the restart policy was not changed before the stop\n' "$1"
    failures=$((failures + 1))
  fi
}

n='alert with the webhook set parks and pages'
if run_case 1 "$n" "CUSTODY_WEBHOOK_URL=$fake_url" -- prod-a probe.log disabled.log; then
  parked "$n"
  out_has "$n" 'CUSTODY ALERT: instance-wide custody stop in two consecutive logs'
  out_has "$n" 'CUSTODY PARKED: prod-a'
  has "$n" curl.stdin "$fake_url"
  has "$n" curl.body 'CUSTODY ALERT on prod-a, parked'
  has "$n" curl.body 'two consecutive logs'
  no_url_leak "$n"
fi

n='alert with the webhook unset parks, logs, and makes no network call'
if run_case 1 "$n" -- prod-a probe.log disabled.log; then
  parked "$n"
  out_has "$n" 'CUSTODY ALERT: instance-wide custody stop'
  out_has "$n" 'CUSTODY_WEBHOOK_URL is unset'
  silent "$n" curl.args
fi

n='a failed page still parks'
if run_case 1 "$n" "CUSTODY_WEBHOOK_URL=$fake_url" FAKE_CURL_EXIT=7 -- prod-a probe.log disabled.log; then
  parked "$n"
  has "$n" curl.args '--config -'
  out_has "$n" 'page failed (curl exit 7)'
  no_url_leak "$n"
fi

n='a URL that is not plain https is not used'
if run_case 1 "$n" 'CUSTODY_WEBHOOK_URL=http://discord.invalid/x' -- prod-a probe.log disabled.log; then
  parked "$n"
  out_has "$n" 'not a plain https URL'
  silent "$n" curl.args
fi

n='a failed park is exit 3 and still pages'
if run_case 3 "$n" "CUSTODY_WEBHOOK_URL=$fake_url" FAKE_DOCKER_FAIL=1 -- prod-a probe.log disabled.log; then
  out_has "$n" 'CUSTODY PARK FAILED'
  has "$n" curl.body 'PARK FAILED'
fi

n='quotes and backslashes in a finding are escaped in the page'
if run_case 1 "$n" "CUSTODY_WEBHOOK_URL=$fake_url" -- prod-a quiet.log quoted.log; then
  has "$n" curl.body 'say \"hi\" \\ there'
fi

n='CUSTODY OK parks nothing and pages nobody'
if run_case 0 "$n" "CUSTODY_WEBHOOK_URL=$fake_url" -- prod-a quiet.log probe.log quiet.log; then
  out_has "$n" 'CUSTODY OK'
  silent "$n" docker.log
  silent "$n" curl.args
fi

n='a check error is exit 2, parks nothing and pages'
if run_case 2 "$n" "CUSTODY_WEBHOOK_URL=$fake_url" -- prod-a quiet.log missing.log; then
  out_has "$n" 'cannot read missing.log'
  out_has "$n" 'CUSTODY CHECK ERROR: prod-a was not checked'
  silent "$n" docker.log
  has "$n" curl.body 'CUSTODY CHECK ERROR on prod-a'
fi

n='a check error with the webhook unset parks nothing and calls nothing'
if run_case 2 "$n" -- prod-a missing.log; then
  silent "$n" docker.log
  silent "$n" curl.args
fi

n='no log is a usage error'
if run_case 2 "$n" -- prod-a; then
  out_has "$n" 'usage: '
  silent "$n" docker.log
fi

n='a container name that is a flag is refused'
if run_case 2 "$n" "CUSTODY_WEBHOOK_URL=$fake_url" -- --all probe.log disabled.log; then
  silent "$n" docker.log
  silent "$n" curl.args
fi

if [ "$failures" -ne 0 ] || [ "$ran" -ne "$expected" ]; then
  printf '%s failure(s), %s of %s expected case(s) ran\n' "$failures" "$ran" "$expected"
  exit 1
fi
echo 'custody-alert-act self-test passed'
