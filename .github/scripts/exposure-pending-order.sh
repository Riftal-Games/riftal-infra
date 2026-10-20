#!/usr/bin/env bash
# Fails unless the bot-proofs job writes exposure=pending in a step of its own
# before any step that is not on the allowlist below (riftal-infra#1237, ADR 024
# item 3). A cancelled run carries the job output of the steps that completed,
# so a bot started before that write leaves bots-stopped-file nothing to file.
#
# Fail-closed on purpose. Naming the steps that start a bot would let a new
# step dodge the name, so instead every step ahead of the pending step must be
# one this file recognises: actions/checkout by commit sha, or a run whose
# every line, comments dropped, is one of allowed_lines. Anything else there
# fails, including a step that only might start a bot. A workflow whose steps
# are all recognised and which writes no pending step yet passes, because no
# step in it can start a bot.
#
# The pending step is one whose whole run text is the single write below, with
# an id, no if: and no continue-on-error:, since either can let a bot start
# without the write having completed. The job's outputs.exposure expression
# must read that id, and no step that completes ahead of it may be read first,
# since the first non-empty operand of || wins.
#
# What it cannot place, it refuses rather than skips: a steps: key with a value
# on its line, a step that is not a block entry, a run scalar that is neither
# one line nor a | block. A script a step calls is not followed, so an edit
# inside one is for review. Reads files only.
set -euo pipefail

workflow="${1:-.github/workflows/ci.yml}"
job="${2:-bot-proofs}"
sep=$'\036'
nl=$'\037'
pending_line="printf 'exposure=pending\\n' >> \"\$GITHUB_OUTPUT\""

allowed_lines() {
  cat <<'EOF'
. .github/scripts/bot-proofs-checks.sh
runner_tools_present
wslconfig_bridged
bots_stopped_clear
printf 'exposure=no-bots\n' >> "$GITHUB_OUTPUT"
if ! address="$(eth0_address)"; then
printf '%s\n' "$address"
exit 1
fi
printf 'eth0 address %s\n' "$address"
printf 'address=%s\n' "$address" >> "$GITHUB_OUTPUT"
bash .github/scripts/ci-docker-label.sh
. images/devtools-image.sh
devtools_extract "$RUNNER_TEMP/riftal-devtools"
bash .github/scripts/ci-container-sweep.sh
EOF
}

if [ ! -r "$workflow" ]; then
  printf '::error::cannot read %s to check exposure=pending comes first\n' "$workflow" >&2
  exit 1
fi

# One record per step in file order: S, name, id, cond, uses, run. cond is 1
# for an if: or a continue-on-error other than false. Then O with the
# outputs.exposure expression, and E with a reason for a shape it cannot place.
# A run's lines are joined with octal 037.
steps_of() {
  awk -v job="$job" -v sep="$sep" -v nl="$nl" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function flush() {
      if (instep) printf "S%s%s%s%s%s%s%s%s%s%s\n", sep, name, sep, id, sep, cond, sep, uses, sep, run
      instep = 0
    }
    function refuse(why) { printf "E%sline %d: %s\n", sep, NR, why }
    { sub(/\r$/, ""); line = $0 }
    inrun {
      if (line ~ /^[ ]*$/) next
      if (indent(line) > 8) {
        t = line; sub(/^ +/, "", t); sub(/ +$/, "", t)
        if (t !~ /^#/) run = run (run == "" ? "" : nl) t
        next
      }
      inrun = 0
    }
    line ~ /^[ ]*(#.*)?$/ { next }
    /^jobs:[ \t]*(#.*)?$/ { injobs = 1; next }
    injobs && /^[^ #]/ { flush(); injobs = 0 }
    !injobs { next }
    indent(line) == 2 {
      flush()
      cur = line; sub(/^ +/, "", cur); sub(/:.*/, "", cur)
      insteps = 0; inouts = 0
      if (cur == job) found = 1
      next
    }
    cur != job { next }
    indent(line) == 4 {
      flush()
      insteps = 0; inouts = 0
      if (line ~ /^    outputs:[ \t]*$/) inouts = 1
      else if (line ~ /^    steps:[ \t]*$/) insteps = 1
      else if (line ~ /^    steps:/) refuse("steps: has a value on its line")
      next
    }
    inouts && line ~ /^      exposure:/ { e = line; sub(/^      exposure:[ ]*/, "", e); print "O" sep e; next }
    !insteps { next }
    indent(line) == 6 && line !~ /^      - / { refuse("a line at step level that is not a block entry"); next }
    {
      if (indent(line) == 6) {
        flush()
        instep = 1; name = id = uses = run = ""; cond = 0
        line = "        " substr(line, 9)
      }
      if (!instep || indent(line) != 8) next
      key = line; sub(/^ +/, "", key)
      val = key; sub(/^[^:]*:[ ]*/, "", val); sub(/:.*/, "", key)
      if (key == "name") name = val
      else if (key == "id") id = val
      else if (key == "uses") uses = val
      else if (key == "if") cond = 1
      else if (key == "continue-on-error") { if (val != "false") cond = 1 }
      else if (key == "run") {
        if (val ~ /^\|[-+]?$/) { inrun = 1 }
        else if (val ~ /^[>|]/) refuse("a run scalar that is neither one line nor a | block")
        else run = val
      }
    }
    END { flush(); if (!found) refuse("no job " job); }' "$workflow"
}

step_allowed() {
  local uses="$1" run="$2" line allow
  if [ -n "$uses" ]; then
    [ -z "$run" ] && [[ "$uses" =~ ^actions/checkout@[0-9a-f]{40}$ ]]
    return
  fi
  [ -n "$run" ] || return 1
  allow=$'\n'"$(allowed_lines)"$'\n'
  while IFS= read -r line; do
    [[ "$allow" == *$'\n'"$line"$'\n'* ]] || return 1
  done <<<"${run//$nl/$'\n'}"
}

failures=0
fail() { printf '::error::%s: %s\n' "$workflow" "$1"; failures=$((failures + 1)); }

declare -A where
expr=""
total=0
before=0
pending_id=""
pending_at=0
while IFS= read -r rec; do
  IFS="$sep" read -r kind name id cond uses run <<<"$rec"
  case "$kind" in
    E) fail "cannot place the $job job: $name"; continue ;;
    O) expr="$name"; continue ;;
  esac
  total=$((total + 1))
  [ -z "$id" ] || where["$id"]="$total"
  [ -z "$pending_id" ] || continue
  if [ "$run" = "$pending_line" ] && [ -z "$uses" ] && [ -n "$id" ] && [ "$cond" -eq 0 ]; then
    pending_id="$id"
    pending_at="$total"
  elif [[ "$run" == *exposure=pending* ]]; then
    fail "step $total ($name) writes exposure=pending but is not one unconditional step with an id whose whole run is: $pending_line"
  elif step_allowed "$uses" "$run"; then
    before=$((before + 1))
  else
    fail "step $total ($name) is ahead of any exposure=pending write and is not on the allowlist, so it may start a bot before the write completes"
  fi
done < <(steps_of)

if [ "$total" -eq 0 ]; then
  fail "no steps found in the $job job"
fi
if [ -z "$expr" ]; then
  fail "the $job job has no outputs.exposure for bots-stopped-file to read"
fi

if [ -n "$pending_id" ]; then
  read_pending=0
  for ref in $(grep -oE 'steps\.[A-Za-z0-9_-]+\.outputs\.exposure' <<<"$expr" || true); do
    ref_id="${ref#steps.}"
    ref_id="${ref_id%.outputs.exposure}"
    if [ "$ref_id" = "$pending_id" ]; then
      read_pending=1
      break
    fi
    if [ -n "${where[$ref_id]:-}" ] && [ "${where[$ref_id]}" -lt "$pending_at" ]; then
      fail "outputs.exposure reads step $ref_id, which completes before the pending step, ahead of it, so exposure=pending can never be the output"
    fi
  done
  if [ "$read_pending" -eq 0 ]; then
    fail "outputs.exposure does not read steps.$pending_id.outputs.exposure"
  fi
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi
if [ -n "$pending_id" ]; then
  printf '%s: %s step(s) ahead of step %s (id %s) writing exposure=pending, all on the allowlist, and outputs.exposure reads it\n' "$job" "$before" "$pending_at" "$pending_id"
else
  printf '%s: %s step(s), all on the allowlist, none can start a bot and no exposure=pending write is needed yet\n' "$job" "$before"
fi
