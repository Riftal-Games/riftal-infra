#!/usr/bin/env bash
# The checks ADR 024 item 3 puts before any container starts in the bot-proofs
# job. Each one has a single timing, reads one source, and refuses with an
# ::error:: when the source is unreadable, times out, or says stop. Sourced by
# the bot-proofs job, one step per check, and by bot-proofs-selftest.sh.
# merge_base_script is not one of them: it fetches, and runs after the pending
# write.

WSLCONFIG="${WSLCONFIG:-/mnt/c/Users/nasir/.wslconfig}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"

# bots-stopped-file calls jq and curl by absolute path and is the only job in
# this workflow that files the stop, so a runner without them must fail here,
# on a run that can still be read, and not when a filing is needed. The riftal
# runners share one distro filesystem, so this holds for whichever one
# bots-stopped-file lands on.
runner_tools_present() {
  local tool
  printf 'runner %s\n' "${RUNNER_NAME:-unknown}"
  for tool in "$JQ_BIN" "$CURL_BIN"; do
    if [ ! -f "$tool" ] || [ ! -x "$tool" ]; then
      printf '::error::%s is not an executable file on runner %s, so bots-stopped-file could not file a stop\n' "$tool" "${RUNNER_NAME:-unknown}"
      return 1
    fi
  done
  printf 'jq and curl present\n'
}

# The mode as configured, which takes effect only at the next WSL restart. A
# key outside [wsl2] does not count and keys are case-insensitive. A second
# [wsl2] section or a second networkingMode key refuses even when one says
# bridged, since which one WSL applies is not worth guessing.
wslconfig_bridged() {
  local text
  if ! text="$(timeout 10 cat "$WSLCONFIG" 2>/dev/null)"; then
    printf '::error::cannot read %s to check networkingMode=bridged\n' "$WSLCONFIG"
    return 1
  fi
  if awk '
      /^[[:space:]]*\[/ {
        section = tolower($0); gsub(/[[:space:]]/, "", section)
        if (section == "[wsl2]") sections++
        next
      }
      section == "[wsl2]" {
        line = tolower($0); gsub(/[[:space:]]/, "", line)
        if (line ~ /^networkingmode=/) { keys++; if (line != "networkingmode=bridged") bad = 1 }
      }
      END { exit !(sections == 1 && keys == 1 && !bad) }' <<<"$text"; then
    printf 'networkingMode=bridged in %s\n' "$WSLCONFIG"
    return 0
  fi
  printf '::error::%s does not set networkingMode=bridged once, under a single [wsl2] section; a bot run needs the mode ADR 016 judged\n' "$WSLCONFIG"
  return 1
}

# Prints the one IPv4 address on eth0, which every socket listing of the run
# is judged against.
eth0_address() {
  local out addr
  if ! out="$(timeout 10 ip -4 -o addr show dev eth0 2>/dev/null)"; then
    printf '::error::cannot read the eth0 address\n'
    return 1
  fi
  addr="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "inet") print $(i + 1) }' <<<"$out" | cut -d/ -f1)"
  if ! [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '::error::eth0 does not hold exactly one IPv4 address, read: "%s"\n' "$addr"
    return 1
  fi
  printf '%s\n' "$addr"
}

# Reads with the job's own GITHUB_TOKEN, which holds issues: read. The issues
# endpoint also lists pull requests, so those are filtered out. A full page
# refuses, since a second page would go unread.
bots_stopped_clear() {
  local api="${GITHUB_API_URL:-https://api.github.com}" body counts total count
  if ! body="$(timeout 30 curl -fsS \
      -H "Authorization: Bearer ${GITHUB_TOKEN:?}" \
      -H 'Accept: application/vnd.github+json' \
      "$api/repos/${GITHUB_REPOSITORY:?}/issues?labels=bots-stopped&state=open&per_page=100")"; then
    printf '::error::cannot read the open bots-stopped issues\n'
    return 1
  fi
  if ! counts="$(jq -er '"\(length) \(map(select(.pull_request == null)) | length)"' <<<"$body")"; then
    printf '::error::the open bots-stopped issues came back unreadable\n'
    return 1
  fi
  total="${counts% *}"
  count="${counts#* }"
  if [ "$total" -ge 100 ]; then
    printf '::error::a full page of bots-stopped items came back; refusing rather than leave a second page unread\n'
    return 1
  fi
  if [ "$count" -ne 0 ]; then
    printf '::error::%s open bots-stopped issue(s): an exposure finding or an overrule stops every bot run until the steward or Nasir closes it\n' "$count"
    return 1
  fi
  printf 'no open bots-stopped issue\n'
}

# $1 the head sha of the PR, or of the push, $2 a directory that does not exist
# yet. Writes main's merge base with that head to $2/sha and its deploy/backup.sh
# to $2/backup.sh. It reads through the API with the job's own read token, so no
# git fetch and no credential in .git/config. The base is main's and not the PR's base branch, which can carry
# the capture request the control must not.
merge_base_script() {
  local api="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?}" base
  if ! base="$(timeout 30 curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN:?}" -H 'Accept: application/vnd.github+json' \
      "$api/compare/main...$1?per_page=1" | jq -er '.merge_base_commit.sha')" || ! [[ $base =~ ^[0-9a-f]{40}$ ]]; then
    printf '::error::cannot read the merge base of %s with main\n' "$1"
    return 1
  fi
  mkdir "$2" || return 1
  if ! timeout 30 curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN:?}" -H 'Accept: application/vnd.github.raw+json' \
      "$api/contents/deploy/backup.sh?ref=$base" -o "$2/backup.sh" || ! [ -s "$2/backup.sh" ]; then
    printf '::error::cannot read deploy/backup.sh at %s\n' "$base"
    return 1
  fi
  printf '%s\n' "$base" >"$2/sha"
  printf 'merge base of %s with main is %s, %s bytes of deploy/backup.sh\n' "$1" "$base" "$(wc -c <"$2/backup.sh")"
}
