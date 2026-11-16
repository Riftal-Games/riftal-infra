#!/usr/bin/env bash
# Self-test for images/release/custody-page.php (riftal-infra#970, riftal-pm
# ADR 055 proof 6), run on the core image's own php with `--network none`, so
# it makes no outward call. Each case is then run against a copy of the pager
# with one line broken and must go red.
set -euo pipefail
# The container's user is not this one and must read every file below.
umask 022

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../images/core-image.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=26
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

core_image || exit 1
work="$(mktemp -d)"
chmod 0755 "$work"
trap 'rm -rf "$work"' EXIT
cp "$DIR/../images/release/custody-page.php" "$work/custody-page.php"
PAGER=custody-page.php
hook=000000000000000000
token=FAKE-TOKEN-selftest-not-a-credential
url="https://discord.com/api/webhooks/$hook/$token"

cat > "$work/findings.txt" <<'EOF'
CUSTODY ALERT: instance-wide custody stop in two consecutive logs: log_archive/a.log:12, then server.log:7
CUSTODY ALERT: player steve_mining refused 3 times: log_archive/a.log:5, server.log:2
CUSTODY ALERT: player alex_digs refused 2 times: log_archive/a.log:6, server.log:3
CUSTODY ALERT: unclassified custody emergency at server.log:44: [RiftalCustody] flushing STEVE_MINING PRIVATE-LOG-TEXT failed
EOF
awk 'BEGIN {
  for (i = 1; i <= 3000; i++) printf "CUSTODY ALERT: unclassified custody emergency at server.log:%d: x\n", i
  printf "CUSTODY ALERT: player "
  for (i = 0; i < 20000; i++) printf "x"
  printf " refused 2 times\n"
}' > "$work/big.txt"

# $1 a file for stdin, then VAR=value pairs, then --, then the php arguments,
# in which @pager is the pager under test. Sets RC, OUT and ERR. The container
# has no network interface.
php_run() {
  local input="$1" env=()
  shift
  while [ "$1" != -- ]; do env+=(-e "$1"); shift; done
  shift
  [ "$1" != @pager ] || set -- "/work/$PAGER" "${@:2}"
  RC=0
  OUT="$(timeout 120 docker run --rm -i -m 1g --cpus 1 --network none --hostname selftest-host \
    -v "$work:/work:ro" "${env[@]}" --entrypoint php "$CORE_IMAGE" "$@" <"$input" 2>"$work/stderr")" || RC=$?
  ERR="$(cat "$work/stderr")"
}
has() { grep -qF -- "$1" <<<"$OUT"; }
streams() { printf '%s\n%s\n' "$OUT" "$ERR"; }

case_page() {
  php_run "$work/findings.txt" INSTANCE_ID=mine-h -- @pager --dry-run park
  [ "$RC" -eq 0 ] && has 'RIFTAL CUSTODY PARK' && has 'Instance: mine-h' &&
    has 'Findings: instance-wide repeat 1, player repeat 2, unclassified 1' &&
    has 'docker logs selftest-host"}' && has '"allowed_mentions":{"parse":[]}' &&
    ! streams | grep -qiE 'steve_mining|alex_digs|PRIVATE-LOG-TEXT|log_archive|server\.log'
}
case_error() {
  php_run /dev/null INSTANCE_ID=mine-h -- @pager --dry-run check-error
  [ "$RC" -eq 0 ] && has 'RIFTAL CUSTODY CHECK ERROR' && has 'repeat 0, player repeat 0, unclassified 0'
}
case_length() {
  php_run "$work/big.txt" "INSTANCE_ID=$(head -c 5000 /dev/zero | tr '\0' a)" -- @pager --dry-run park
  [ "$RC" -eq 0 ] && has 'Instance: unknown-instance' && has 'player repeat 1, unclassified 3000' &&
    [ "${#OUT}" -lt 2000 ]
}
case_ascii() {
  php_run "$work/findings.txt" $'INSTANCE_ID=mine-\xc3\xa9' -- @pager --dry-run park
  [ "$RC" -eq 0 ] && has 'Instance: unknown-instance' &&
    [ -z "$(printf '%s' "$OUT" | LC_ALL=C tr -d '\000-\177')" ]
}
case_send_failure() {
  php_run "$work/findings.txt" "RIFTAL_CUSTODY_WEBHOOK_URL=$url" -- @pager park
  [ "$RC" -eq 1 ] && [ "$OUT" = 'page failed' ] && ! streams | grep -qF -e "$token" -e "$hook"
}
case_dry_run() {
  php_run "$work/findings.txt" "RIFTAL_CUSTODY_WEBHOOK_URL=$url" -- @pager --dry-run park
  [ "$RC" -eq 0 ] && has 'Instance: ' && ! streams | grep -qE "page (sent|failed)|$token"
}
case_refusals() {
  local bad
  php_run "$work/findings.txt" -- @pager park
  [ "$RC" -eq 1 ] && [ "$OUT" = 'no page sent' ] || return 1
  for bad in "http://discord.com/api/webhooks/$hook/$token" \
    "https://discord.com.example.invalid/api/webhooks/$hook/$token" \
    "https://example.invalid/api/webhooks/$hook/$token" "https://discord.com/api/webhooks/" \
    "https://discordapp.com/api/webhooks/$hook/$token and more"; do
    php_run "$work/findings.txt" "RIFTAL_CUSTODY_WEBHOOK_URL=$bad" -- @pager park
    [ "$RC" -eq 1 ] && [ "$OUT" = 'no page sent' ] && [ -z "$ERR" ] || return 1
  done
}
case_argv() {
  php_run "$work/findings.txt" -- @pager park "$url"
  [ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -qF 'usage: custody-page.php' <<<"$ERR" &&
    ! streams | grep -qF -e "$token" -e "$hook"
}
case_test() {
  php_run /dev/null -- @pager --dry-run --test
  [ "$RC" -eq 0 ] && has 'RIFTAL CUSTODY TEST' && ! has 'Findings'
}
case_bound() {
  grep -qxF 'const SEND_SECONDS = 10;' "$work/$PAGER" &&
    grep -qF 'CURLOPT_TIMEOUT => SEND_SECONDS' "$work/$PAGER" &&
    grep -qF 'CURLOPT_CONNECTTIMEOUT => SEND_SECONDS' "$work/$PAGER"
}
case_image() {
  php_run /dev/null -- -r 'exit(function_exists("curl_init") && @fsockopen("1.1.1.1", 443, $c, $t, 3) === false ? 0 : 1);'
  [ "$RC" -eq 0 ]
}

for entry in \
  "page|a park page holds the instance id, the counts and the logs pointer, and names no player" \
  "error|a check error page holds the instance id and zero counts" \
  "length|a 5000-character id and 3000 findings keep the page under 2000 characters" \
  "ascii|a non-ASCII id is replaced, so the page is plain ASCII" \
  "send_failure|a failed send prints page failed and no part of the URL" \
  "dry_run|--dry-run sends nothing and prints no part of the URL" \
  "refusals|an unset or non-Discord URL prints no page sent" \
  "argv|a URL given as an argument is refused unread" \
  "test|--test is one fixed message" \
  "bound|the send is bounded at 10 seconds" \
  "image|the image's php has ext-curl and this container has no route out"; do
  if "case_${entry%%|*}"; then pass "${entry#*|}"; else fail "${entry#*|}"; fi
done

# $1 what is broken, $2 the case that must go red, $3 the pager text to
# replace, $4 its replacement.
mutant() {
  local src mutated
  src="$(cat "$DIR/../images/release/custody-page.php"; printf x)"
  src="${src%x}"
  mutated="${src//"$3"/"$4"}"
  if [ "$mutated" = "$src" ]; then
    fail "breaking $1 changed nothing in the pager"
    return
  fi
  printf '%s' "$mutated" > "$work/mutant.php"
  PAGER=mutant.php
  if "case_$2"; then fail "$2 stayed green with $1 broken"; else pass "$2 goes red with $1 broken"; fi
  PAGER=custody-page.php
}

name_check="'/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\$/D'"
url_check='!is_string($url) || preg_match(URL_PATTERN, $url) !== 1'
mutant 'the instance line' page '"Instance: "' '"Instance: x"'
mutant 'the instance-wide kind' page '"CUSTODY ALERT: instance-wide custody stop"' '"CUSTODY ALERT: instance-wide custody stoq"'
mutant 'the logs pointer' page 'docker logs "' 'docker log "'
mutant 'the mentions filter' page '["parse" => []]' '["parse" => ["everyone"]]'
mutant 'the check error heading' error 'CHECK ERROR: the logs' 'CHECKED: the logs'
mutant 'the quiet counting' page '$counts[$index]++;' '$counts[$index]++; echo $chunk;'
mutant 'the name check, for the length' length "$name_check" "'/^.*\$/Ds'"
mutant 'the name check, for ASCII' ascii "$name_check" "'/^.*\$/Ds'"
mutant 'the failure line' send_failure '"page failed\n"' '"page failed $url\n"'
mutant 'the dry run' dry_run 'if($dryRun){' 'if(false){'
mutant 'the URL check' refusals "$url_check" 'false'
mutant 'the unset URL check' refusals "$url_check" 'is_string($url) && preg_match(URL_PATTERN, $url) !== 1'
mutant 'the usage line' argv '|--test\n");' '|--test {$args[1]}\n");'
mutant 'the test message' test 'RIFTAL CUSTODY TEST' 'x'
mutant 'the bound' bound 'const SEND_SECONDS = 10;' 'const SEND_SECONDS = 100;'

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed: the custody pager is bounded, quiet and cannot leak the URL.\n' "$PASSES"
