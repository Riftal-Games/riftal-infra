#!/usr/bin/env bash
# Holds every hand-translated `wslc run` in the given docs to the
# images/compose.yaml service it stands in for (riftal-infra#402). wslc has no
# compose verb, so these commands are copies, and a copy drifts unseen.
#
# A command's `--name riftal-<service>` names its service. Its -e, -v, -p,
# --memory, --cpus, --network, -i, image and command must match that service
# in `docker compose config --no-interpolate`, so a ${VAR} compares as written
# and no images/.env is needed. Restart policy and healthcheck have no wslc
# flag and are not compared. A flag this script does not know fails the run
# rather than slip past it.
#
# Usage: wslc-drift.sh [doc ...], docs/dev-stack-two-instance.md by default.
# Exits non-zero naming every difference. Needs docker compose and jq, and
# starts no container.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
COMPOSE="${WSLC_DRIFT_COMPOSE:-$ROOT/images/compose.yaml}"
[ "$#" -gt 0 ] || set -- "$ROOT/docs/dev-stack-two-instance.md"
command -v jq >/dev/null || { printf '::error::jq is required\n'; exit 1; }

model="$(docker compose -f "$COMPOSE" config --format json --no-interpolate)"

# Prints one shell word per line for each `wslc run` in $1, its continuation
# lines joined, with a blank line after each command. xargs strips the quotes
# the way the shell would and leaves every $ unexpanded.
commands() {
  awk '/^wslc run / { on = 1; line = "" }
    on { cont = sub(/\\$/, ""); line = line $0; if (!cont) { print line; on = 0 } }' "$1" |
    while IFS= read -r line; do
      xargs printf '%s\n' <<<"${line#wslc run }"
      printf '\n'
    done
}

# The service's flags in the doc's form, one per line, sorted.
expected() {
  jq -r --arg s "$1" --arg root "$ROOT" '. as $m | .services[$s]
    | ((.environment // {}) | to_entries[] | select(.value != null) | "-e \(.key)=\(.value)"),
      (.volumes[]? | "-v \(if .type == "bind" and (.source | startswith($root + "/"))
        then "$INFRA" + (.source | ltrimstr($root)) else .source end):\(.target)\(if .read_only then ":ro" else "" end)"),
      (.ports[]? | "-p \(if type == "string" then . else "\(.host_ip):\(.published):\(.target)/\(.protocol)" end)"
        | if test("/") then . else . + "/tcp" end),
      (.networks // {} | keys[] | "--network \($m.networks[.].name // .)"),
      (if .mem_limit then "--memory \(.mem_limit)" else empty end),
      (if .cpus then "--cpus \(.cpus)" else empty end),
      (if .stdin_open then "-i" else empty end),
      "image \(.image)",
      "command \(.command // [] | @json)"' <<<"$model" | sort
}

# Reads one command's words on stdin; prints its service, then its flags in
# the form expected() prints, sorted. Unknown flags print as `unknown <flag>`.
documented() {
  local name="" flags=() rest=() word
  while IFS= read -r word && [ -n "$word" ]; do
    if [ "${#rest[@]}" -gt 0 ]; then rest+=("$word"); continue; fi
    case "$word" in
      -d) ;;
      -i) flags+=("-i") ;;
      --name) IFS= read -r name ;;
      --network-alias) IFS= read -r word; flags+=("--network-alias $word") ;;
      -e|-v|-p|--network|--memory|--cpus)
        local flag="$word"
        IFS= read -r word
        if [ "$flag" = -p ] && [[ "$word" != */* ]]; then word="$word/tcp"; fi
        # Compose prints every variable braced, and $X and ${X} expand alike.
        if [ "$flag" = -e ]; then word="$(sed -E 's/\$([A-Za-z_][A-Za-z0-9_]*)/${\1}/g' <<<"$word")"; fi
        flags+=("$flag $word") ;;
      -*) flags+=("unknown $word") ;;
      *) rest+=("$word") ;;
    esac
  done
  printf '%s\n' "${name#riftal-}"
  {
    [ "${#flags[@]}" -eq 0 ] || printf '%s\n' "${flags[@]}"
    printf 'image %s\n' "${rest[0]:-}"
    printf 'command %s\n' "$(printf '%s\n' "${rest[@]:1}" | jq -Rnc '[inputs | select(. != "")]')"
  } | sort
}

status=0
for doc in "$@"; do
  found=0
  words="$(commands "$doc")"
  while IFS= read -r -d '' cmd; do
    [ -n "${cmd//$'\n'/}" ] || continue
    found=$((found + 1))
    out="$(documented <<<"$cmd")"
    service="$(head -n1 <<<"$out")"
    got="$(tail -n +2 <<<"$out")"
    if ! jq -e --arg s "$service" '.services[$s]' <<<"$model" >/dev/null; then
      printf '::error::%s: wslc run --name riftal-%s names no service in %s\n' "$doc" "$service" "$COMPOSE"
      status=1
      continue
    fi
    # A --network-alias is right only when it is the service name, the alias
    # compose gives every service.
    want="$(expected "$service"; grep -x -- "--network-alias $service" <<<"$got" || true)"
    want="$(sort <<<"$want")"
    if [ "$got" = "$want" ]; then
      printf '  ok    %s: riftal-%s matches compose service %s\n' "$doc" "$service" "$service"
    else
      printf '::error::%s: riftal-%s differs from compose service %s (< doc, > compose)\n' "$doc" "$service" "$service"
      diff <(printf '%s\n' "$got") <(printf '%s\n' "$want") | grep '^[<>]' || true
      status=1
    fi
  done < <(awk 'BEGIN { RS = ""; ORS = "\0" } { print }' <<<"$words")
  if [ "$found" -eq 0 ]; then
    printf '::error::%s: no wslc run command found, so nothing was compared\n' "$doc"
    status=1
  fi
done
exit "$status"
