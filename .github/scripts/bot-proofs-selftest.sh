#!/usr/bin/env bash
# Self-test for bot-proofs-checks.sh and images/devtools-image.sh (riftal-infra#1225).
# Fakes stand in for docker, curl and ip, so every refusal can be shown
# without a daemon, a token or a network, and the committed pin's file shape is
# the only real input.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/bot-proofs-checks.sh"
. "$DIR/../../images/devtools-image.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=16
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
PATH="$work/bin:$PATH"

# $1 command name, the script body is read from stdin.
fake() {
  { printf '#!/bin/sh\n'; cat; } > "$work/bin/$1"
  chmod +x "$work/bin/$1"
}

# $1 case, $2 expected status (ok or refused), $3 text the output must hold
expect() {
  local what="$1" want="$2" text="$3" out status=0
  shift 3
  out="$("$@" 2>&1)" || status=$?
  if [ "$want" = ok ] && [ "$status" -eq 0 ] && grep -qF "$text" <<<"$out"; then
    pass "$what: $out"
  elif [ "$want" = refused ] && [ "$status" -ne 0 ] && grep -qF '::error::' <<<"$out" && grep -qF "$text" <<<"$out"; then
    pass "$what is refused: $out"
  else
    fail "$what: wanted $want with \"$text\", got status $status: $out"
  fi
}

conf="$work/wslconfig"
export WSLCONFIG="$conf"
printf '[wsl2]\nmemory=12GB\nNetworkingMode = bridged\n' > "$conf"
expect "bridged under [wsl2]" ok "networkingMode=bridged" wslconfig_bridged
printf '[wsl2]\nnetworkingMode=mirrored\n' > "$conf"
expect "mirrored" refused "does not set networkingMode=bridged" wslconfig_bridged
printf '[experimental]\nnetworkingMode=bridged\n[wsl2]\nmemory=1GB\n' > "$conf"
expect "bridged outside [wsl2]" refused "does not set networkingMode=bridged" wslconfig_bridged
WSLCONFIG="$work/absent" expect "a missing .wslconfig" refused "cannot read" wslconfig_bridged

fake ip <<'EOF'
printf '2: eth0    inet 192.168.0.223/24 brd 192.168.0.255 scope global eth0\n'
EOF
expect "one eth0 address" ok "192.168.0.223" eth0_address
fake ip <<'EOF'
exit 0
EOF
expect "no eth0 address" refused "exactly one IPv4 address" eth0_address

export GITHUB_TOKEN=unused GITHUB_REPOSITORY=Riftal-Games/riftal-infra
fake curl <<'EOF'
printf '[]'
EOF
expect "no open bots-stopped issue" ok "no open bots-stopped issue" bots_stopped_clear
fake curl <<'EOF'
printf '[{"number":9,"pull_request":{}}]'
EOF
expect "a pull request carrying the label" ok "no open bots-stopped issue" bots_stopped_clear
fake curl <<'EOF'
printf '[{"number":9}]'
EOF
expect "an open bots-stopped issue" refused "1 open bots-stopped" bots_stopped_clear
fake curl <<'EOF'
exit 22
EOF
expect "an unreadable issue list" refused "cannot read the open" bots_stopped_clear

sha=0123456789abcdef0123456789abcdef01234567
printf '%s\n' "$sha" > "$work/pin.sha"
log="$work/docker.log"
fake docker <<EOF
printf '%s\n' "\$*" >> "$log"
case "\$1 \$2" in
  "image inspect") [ "\${FAKE_TAG:-yes}" = yes ] && { [ "\$3" = --format ] && echo sha256:abc; exit 0; }; exit 1 ;;
esac
exit 0
EOF
export GITHUB_RUN_ID=77 GITHUB_RUN_ATTEMPT=2
expect "a present tag" ok "riftal-devtools:$sha (sha256:abc)" devtools_extract "$work/out" "$work/pin.sha"
if grep -qE '^create --rm -m 1g --cpus 1 --name riftal_smoke_ci_77_2_devtools riftal-devtools:' "$log" \
    && grep -qE '^rm -v riftal_smoke_ci_77_2_devtools$' "$log"; then
  pass "the container is created limited and removed with -v"
else
  fail "the docker calls were not a limited create and an rm -v: $(cat "$log")"
fi
: > "$log"
FAKE_TAG=no expect "a tag not on the daemon" refused "is not on this Docker daemon" devtools_extract "$work/out" "$work/pin.sha"
if [ ! -s "$log" ] || ! grep -qE '^(pull|create) ' "$log"; then
  pass "a missing tag is never pulled or created"
else
  fail "a missing tag reached pull or create: $(cat "$log")"
fi
mkdir "$work/there"
expect "a destination that exists" refused "already exists" devtools_extract "$work/there" "$work/pin.sha"
printf 'latest\n' > "$work/pin.sha"
expect "a pin that is not a sha" refused "not a full 40-character" devtools_image "$work/pin.sha"

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
printf 'all %s assertions passed: the bot-proofs checks refuse or pass as written.\n' "$PASSES"
