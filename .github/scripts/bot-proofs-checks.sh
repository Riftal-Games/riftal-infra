#!/usr/bin/env bash
# The checks ADR 024 item 3 puts before any container starts in the bot-proofs
# job. Each one has a single timing, reads one source, and refuses with an
# ::error:: when the source is unreadable, times out, or says stop. Sourced by
# the bot-proofs job, one step per check, and by bot-proofs-selftest.sh.

WSLCONFIG="${WSLCONFIG:-/mnt/c/Users/nasir/.wslconfig}"

# The mode as configured, which takes effect only at the next WSL restart. A
# key outside [wsl2] does not count, and keys are case-insensitive.
wslconfig_bridged() {
  local text
  if ! text="$(timeout 10 cat "$WSLCONFIG" 2>/dev/null)"; then
    printf '::error::cannot read %s to check networkingMode=bridged\n' "$WSLCONFIG"
    return 1
  fi
  if awk '
      /^[[:space:]]*\[/ { section = tolower($0); gsub(/[[:space:]]/, "", section); next }
      section == "[wsl2]" {
        line = tolower($0); gsub(/[[:space:]]/, "", line)
        if (line == "networkingmode=bridged") found = 1
      }
      END { exit !found }' <<<"$text"; then
    printf 'networkingMode=bridged in %s\n' "$WSLCONFIG"
    return 0
  fi
  printf '::error::%s does not set networkingMode=bridged under [wsl2]; a bot run needs the mode ADR 016 judged\n' "$WSLCONFIG"
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
# endpoint also lists pull requests, so those are filtered out.
bots_stopped_clear() {
  local api="${GITHUB_API_URL:-https://api.github.com}" body count
  if ! body="$(timeout 30 curl -fsS \
      -H "Authorization: Bearer ${GITHUB_TOKEN:?}" \
      -H 'Accept: application/vnd.github+json' \
      "$api/repos/${GITHUB_REPOSITORY:?}/issues?labels=bots-stopped&state=open&per_page=100")"; then
    printf '::error::cannot read the open bots-stopped issues\n'
    return 1
  fi
  if ! count="$(jq -er 'map(select(.pull_request == null)) | length' <<<"$body")"; then
    printf '::error::the open bots-stopped issues came back unreadable\n'
    return 1
  fi
  if [ "$count" -ne 0 ]; then
    printf '::error::%s open bots-stopped issue(s): an exposure finding or an overrule stops every bot run until the steward or Nasir closes it\n' "$count"
    return 1
  fi
  printf 'no open bots-stopped issue\n'
}
