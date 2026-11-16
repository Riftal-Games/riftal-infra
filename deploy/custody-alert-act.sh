#!/usr/bin/env bash
# Acts on custody-alert-check.sh for one production instance (riftal-infra#970,
# riftal-pm ADR 017 item 4): on a CUSTODY ALERT it parks the instance's
# container and pages a Discord webhook.
#
#   custody-alert-act.sh <container> <log> [<log> ...]
#     0  CUSTODY OK, nothing done
#     1  CUSTODY ALERT, the container parked (the page may still have failed)
#     2  the check could not decide (usage, unreadable or mis-split logs):
#        nothing parked, a page attempted, never a pass
#     3  CUSTODY ALERT but the park failed; the page was still attempted
#
# CUSTODY_WEBHOOK_URL is a deploy secret with no default. Unset, the alert is
# logged and the instance still parked. CUSTODY_RUNTIME names the container
# CLI, docker by default.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${CUSTODY_CHECK:-$SCRIPT_DIR/custody-alert-check.sh}"
RUNTIME="${CUSTODY_RUNTIME:-docker}"
# Long enough for PocketMine to finish its shutdown saves before docker sends
# SIGKILL.
STOP_TIMEOUT=60

if [ "$#" -lt 2 ]; then
  echo 'usage: custody-alert-act.sh <container> <log> [<log> ...], logs one per process lifetime, oldest first' >&2
  exit 2
fi
container="$1"
shift
if ! [[ $container =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "custody-alert-act.sh: $container is not a container name" >&2
  exit 2
fi

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s" | tr -d '\000-\037'
}

# The URL reaches curl on stdin as a config line, never on its command line,
# and curl's own output is discarded because its errors can quote the URL.
page() {
  local url="${CUSTODY_WEBHOOK_URL:-}" body rc=0
  if [ -z "$url" ]; then
    echo 'custody-alert-act.sh: CUSTODY_WEBHOOK_URL is unset, no page sent' >&2
    return 0
  fi
  if [[ $url != https://* ]] || [[ $url == *[[:space:]\"\\]* ]]; then
    echo 'custody-alert-act.sh: CUSTODY_WEBHOOK_URL is not a plain https URL, no page sent' >&2
    return 1
  fi
  body="$(mktemp)"
  # Discord rejects content over 2000 characters.
  printf '{"allowed_mentions":{"parse":[]},"content":"%s"}\n' "$(json_escape "${1:0:1500}")" >"$body"
  printf 'url = "%s"\n' "$url" |
    curl --silent --fail --max-time 10 --config - \
      --header 'Content-Type: application/json' --data-binary "@$body" \
      --output /dev/null >/dev/null 2>&1 || rc=$?
  rm -f "$body"
  if [ "$rc" -ne 0 ]; then
    echo "custody-alert-act.sh: page failed (curl exit $rc)" >&2
    return 1
  fi
  echo 'custody-alert-act.sh: page sent'
}

set +e
out="$(bash "$CHECK" "$@" 2>&1)"
rc=$?
set -e

case "$rc" in
0)
  printf '%s\n' "$out"
  exit 0
  ;;
1)
  printf '%s\n' "$out"
  parked=1
  # The restart policy goes first so a crash between the two calls is not
  # restarted.
  if "$RUNTIME" update --restart=no "$container" >/dev/null &&
    "$RUNTIME" stop -t "$STOP_TIMEOUT" "$container" >/dev/null; then
    parked=0
    echo "CUSTODY PARKED: $container stopped with restart policy no until an operator clears it"
    state='parked, restart policy no'
  else
    echo "CUSTODY PARK FAILED: $container could not be stopped with restart policy no" >&2
    state='PARK FAILED, the instance may still be running'
  fi
  page "CUSTODY ALERT on $container, $state:"$'\n'"$out" || true
  [ "$parked" -eq 0 ] && exit 1
  exit 3
  ;;
*)
  printf '%s\n' "$out" >&2
  echo "CUSTODY CHECK ERROR: $container was not checked and is not parked" >&2
  page "CUSTODY CHECK ERROR on $container, not parked and not checked:"$'\n'"$out" || true
  exit 2
  ;;
esac
