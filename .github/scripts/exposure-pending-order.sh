#!/usr/bin/env bash
# Fails unless the bot-proofs job writes exposure=pending in a step of its own
# before any step that is not on the allowlist below (riftal-infra#1237, ADR 024
# item 3). A cancelled run carries the job output of the steps that completed,
# so a bot started before that write leaves bots-stopped-file nothing to file.
#
# Fail-closed for what it reads: a workflow, job or step key off the lists
# below, a step shape it cannot place, and odd indentation below 10 spaces are
# refused. Places it does not read are under Limits. Listed, with every key
# compared after its quotes and spaces are stripped:
#   workflow keys  name, on, permissions, concurrency, env, jobs. env may hold
#                  only HADOLINT_VERSION and HADOLINT_SHA256.
#   job keys       name, runs-on, timeout-minutes, permissions, outputs, steps.
#   step keys      name, id, uses, if, continue-on-error, run, env, with. env
#                  may hold only GITHUB_TOKEN. with is for actions/checkout by
#                  commit sha and may hold only persist-credentials.
# Every step up to and including the pending step is judged: actions/checkout,
# or a run whose every line, comments dropped, is one of allowed_lines, and a
# plain run scalar must be one line. The pending step is one whose whole run
# is the single write below, with an id and no uses:, no if:, no env or with
# block and no key but name, id, run and continue-on-error. Its
# continue-on-error is accepted only as false.
# outputs.exposure must be exactly a || chain of steps.<id>.outputs.exposure
# operands that includes the pending step's operand, since the first non-empty
# operand wins. No operand placed before the pending one may belong to a step
# that completes ahead of the pending step. Operands after it are not judged.
#
# Limits, deliberate: 2-space indentation only, and flow-style or folded run
# values are refused as unplaceable. A script a step calls is not followed, so
# an edit inside one is for review. Steps after the pending step are placed but
# not judged, and other jobs are not read. Reads files only. Also not read:
#   children of the workflow keys on, permissions and concurrency;
#   children of the job keys name, runs-on, timeout-minutes and permissions;
#   outputs keys other than exposure;
#   a line indented 11 or more spaces outside a run;
#   the values under a step's env and with keys, so persist-credentials: true
#   on actions/checkout is accepted.
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

# One record per step in file order: S, name, id, cond, uses, bad, opts, run.
# cond is 1 for an if: or a continue-on-error other than false. bad is the
# first key or shape of the step off the lists in the header. opts holds e for
# an env block and w for a with block. Then O with the outputs.exposure
# expression, and E with a reason for a shape it cannot place. A run's lines
# are joined with octal 037.
steps_of() {
  awk -v job="$job" -v sep="$sep" -v nl="$nl" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function key(s) { sub(/^ +/, "", s); sub(/:.*/, "", s); gsub("[\"\047 ]", "", s); return s }
    function val(s) { sub(/^ +/, "", s); sub(/^[^:]*:[ ]*/, "", s); sub(/[ ]+$/, "", s); return s }
    function empty(v) { return v == "" || v ~ /^#/ }
    function allowed(list, k) { return index(" " list " ", " " k " ") > 0 }
    function refuse(why) { printf "E%sline %d: %s\n", sep, NR, why }
    function setbad(why) { if (bad == "") bad = why }
    function flush() {
      if (instep) printf "S%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", sep, name, sep, id, sep, cond, sep, uses, sep, bad, sep, opts, sep, run
      instep = 0
    }
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
    indent(line) == 0 {
      flush(); injobs = 0; topenv = 0; k = key(line)
      if (!allowed("name on permissions concurrency env jobs", k)) refuse("top-level key " k " is not on the allowlist")
      else if ((k == "env" || k == "jobs") && !empty(val(line))) refuse(k ": has a value on its line")
      else if (k == "jobs") injobs = 1
      else if (k == "env") topenv = 1
      next
    }
    !injobs {
      if (topenv && (indent(line) != 2 || !allowed("HADOLINT_VERSION HADOLINT_SHA256", key(line)))) refuse("workflow env variable " key(line) " is not on the allowlist")
      next
    }
    indent(line) == 2 {
      flush(); cur = key(line); jsect = ""
      if (cur == job) {
        found = 1
        if (!empty(val(line))) refuse("the job line has a value")
      }
      next
    }
    cur != job { next }
    indent(line) < 10 && indent(line) % 2 { refuse("odd indentation"); next }
    indent(line) == 4 {
      flush(); k = key(line); jsect = ""; och = 0
      if (!allowed("name runs-on timeout-minutes permissions outputs steps", k)) refuse("job key " k " is not on the allowlist")
      else if (k in jseen) refuse("duplicate job key " k)
      else if ((k == "outputs" || k == "steps") && !empty(val(line))) refuse(k ": has a value on its line")
      else if (k == "outputs" || k == "steps") jsect = k
      jseen[k] = 1
      next
    }
    jsect == "outputs" {
      if (!och) och = indent(line)
      if (indent(line) == och && key(line) == "exposure") {
        if (nexp++) refuse("outputs.exposure is given twice")
        print "O" sep val(line)
      }
      next
    }
    jsect != "steps" { next }
    indent(line) == 6 {
      flush()
      if (line !~ /^      - [^ #]/) { refuse("a step entry that is not in the form - key: value"); next }
      instep = 1; name = id = uses = bad = opts = run = ""; cond = 0; ssect = ""; sch = 0
      split("", sseen)
      line = "        " substr(line, 9)
    }
    !instep { refuse("a line under steps that is not inside a step entry"); next }
    indent(line) > 8 {
      if (ssect == "plainrun") setbad("a run scalar that continues past its first line")
      else if (ssect == "env" || ssect == "with") {
        if (!sch) sch = indent(line)
        k = key(line)
        if (indent(line) == sch && !allowed(ssect == "env" ? "GITHUB_TOKEN" : "persist-credentials", k)) setbad("the " ssect (ssect == "env" ? " variable " : " key ") k)
      }
      next
    }
    {
      k = key(line); v = val(line); ssect = ""
      if (k in sseen) setbad("a duplicate key " k)
      sseen[k] = 1
      if (!allowed("name id uses if continue-on-error run env with", k)) setbad("the key " k)
      else if (k == "name") name = v
      else if (k == "id") id = v
      else if (k == "uses") uses = v
      else if (k == "if") cond = 1
      else if (k == "continue-on-error") { if (v != "false") cond = 1 }
      else if (k == "run") {
        if (v ~ /^\|[-+]?$/) inrun = 1
        else if (v ~ /^[>|]/) setbad("a run scalar that is neither one line nor a | block")
        else { run = v; ssect = "plainrun" }
      }
      else if (!empty(v)) setbad("the key " k " with a value on its line")
      else { ssect = k; sch = 0; opts = opts substr(k, 1, 1) }
    }
    END { flush(); if (!found) refuse("no job " job) }' "$workflow"
}

reason=""

step_allowed() {
  local uses="$1" run="$2" opts="$3" bad="$4" line allow
  if [ -n "$bad" ]; then
    reason="it has $bad"
    return 1
  fi
  if [ -n "$uses" ]; then
    if [ -z "$run" ] && [[ "$uses" =~ ^actions/checkout@[0-9a-f]{40}$ ]]; then
      return 0
    fi
    reason="it uses $uses, which is not actions/checkout by commit sha with no run"
    return 1
  fi
  if [[ "$opts" == *w* ]]; then
    reason="it has a with block and is not actions/checkout"
    return 1
  fi
  if [ -z "$run" ]; then
    reason="it has no run"
    return 1
  fi
  allow=$'\n'"$(allowed_lines)"$'\n'
  while IFS= read -r line; do
    [[ "$allow" == *$'\n'"$line"$'\n'* ]] || { reason="the run line '$line' is not on the allowlist"; return 1; }
  done <<<"${run//$nl/$'\n'}"
}

pending_step() {
  if [ -n "$uses" ]; then reason="it has uses"
  elif [ "$run" != "$pending_line" ]; then reason="its run is not that single write"
  elif [ -z "$id" ]; then reason="it has no id"
  elif [ "$cond" -ne 0 ]; then reason="it has an if: or continue-on-error:"
  elif [ -n "$bad" ]; then reason="it has $bad"
  elif [ -n "$opts" ]; then reason="it has an env or with block"
  else return 0
  fi
  return 1
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
  IFS="$sep" read -r kind name id cond uses bad opts run <<<"$rec"
  case "$kind" in
    E) fail "cannot place the $job job: $name"; continue ;;
    O) expr="$name"; continue ;;
  esac
  total=$((total + 1))
  [ -z "$id" ] || where["$id"]="$total"
  [ -z "$pending_id" ] || continue
  if pending_step; then
    pending_id="$id"
    pending_at="$total"
  elif [[ "$run" == *exposure=pending* ]]; then
    fail "step $total ($name) writes exposure=pending but is not one unconditional step with an id whose whole run is: $pending_line, with no uses:, if:, env or with block, no continue-on-error other than false, and no key but name, id, run and continue-on-error: $reason"
  elif step_allowed "$uses" "$run" "$opts" "$bad"; then
    before=$((before + 1))
  else
    fail "step $total ($name) is ahead of any exposure=pending write and is not on the allowlist, so it may start a bot before the write completes: $reason"
  fi
done < <(steps_of)

if [ "$total" -eq 0 ]; then
  fail "no steps found in the $job job"
fi
if [ -z "$expr" ]; then
  fail "the $job job has no outputs.exposure for bots-stopped-file to read"
fi

operand='steps\.[A-Za-z0-9_-]+\.outputs\.exposure'
chain='^\$\{\{ steps\.[A-Za-z0-9_-]+\.outputs\.exposure( \|\| steps\.[A-Za-z0-9_-]+\.outputs\.exposure)* \}\}$'
if [ -n "$expr" ] && ! [[ "$expr" =~ $chain ]]; then
  fail "outputs.exposure is not exactly a || chain of steps.<id>.outputs.exposure operands: $expr"
elif [ -n "$pending_id" ]; then
  read_pending=0
  for ref in $(grep -oE "$operand" <<<"$expr"); do
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
