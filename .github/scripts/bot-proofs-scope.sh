#!/usr/bin/env bash
# Sourced, not run, by the bot-proofs-scope job and bot-proofs-scope-selftest.sh
# (riftal-infra#1231). Decides whether a change can start a bot, so that
# bot-proofs and its bots-stopped check run only where there is a bot to stop.
# A path serves unless it is shown not to, and every error ends in serves=true.

# NUL-separated changed paths on stdin. Prints each path, then one line:
# serves=false when every path is under docs/, designer/ or proxy/ or is a
# *.md file at the repository root, and serves=true otherwise, including when
# there is no path at all.
scope_classify() {
  local path count=0 serves=false
  while IFS= read -r -d '' path; do
    count=$((count + 1))
    # %q keeps a path from starting a line the runner reads as a command.
    printf 'changed %q\n' "$path"
    case "$path" in
      docs/* | designer/* | proxy/*) ;;
      */*) serves=true ;;
      *.md) ;;
      *) serves=true ;;
    esac
  done
  if [ "$count" -eq 0 ]; then
    printf 'no changed path, so nothing shows this change cannot start a bot\n'
    serves=true
  fi
  printf 'serves=%s\n' "$serves"
}

# $1 event name, $2 base sha, $3 head sha, $4 file that receives the verdict
# (default /dev/null). Prints the changed paths and the verdict, and appends
# the verdict to $4 once, last.
scope_run() {
  local event="$1" base="$2" head="$3" out="${4:-/dev/null}" range tmp verdict
  case "$event" in
    pull_request) range="$base...$head" ;;
    push) range="$base..$head" ;;
    *)
      printf 'event %s is not one this check reads\n' "$event"
      printf 'serves=true\n' | tee -a "$out"
      return 0
      ;;
  esac
  if ! [[ "$base" =~ ^[0-9a-f]{40}$ ]] || [[ "$base" =~ ^0+$ ]] || ! [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'base %s and head %s are not both usable commits\n' "${base:-empty}" "${head:-empty}"
    printf 'serves=true\n' | tee -a "$out"
    return 0
  fi
  tmp="$(mktemp)"
  # --no-renames lists both ends of a rename, so a move out of a serving path
  # into docs/ still shows the serving path.
  if ! git diff --name-only --no-renames -z "$range" -- > "$tmp"; then
    rm -f "$tmp"
    printf 'git diff %s failed\n' "$range"
    printf 'serves=true\n' | tee -a "$out"
    return 0
  fi
  printf 'diff %s\n' "$range"
  verdict="$(scope_classify < "$tmp")"
  rm -f "$tmp"
  printf '%s\n' "$verdict"
  printf '%s\n' "$verdict" | grep '^serves=' | tail -n 1 >> "$out"
}
