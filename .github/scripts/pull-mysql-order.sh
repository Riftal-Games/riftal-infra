#!/usr/bin/env bash
# Fails unless, in every job of the workflow at $1, a step running
# .github/scripts/pull-mysql.sh comes before every step that runs mysql:8
# (riftal-infra#962). A self-test that starts mysql:8 ahead of the pull runs
# the runner's cached copy of a floating tag, and CI stays green while it does.
#
# A step runs mysql:8 when its run text, or a script that text names in the
# form `bash <path>` or `sh <path>`, starts a container and names mysql:8
# outside a comment. Only that form is followed, one level deep, with an
# unquoted path and no flag before it. A self-test started any other way, by
# direct exec, a quoted or flagged path, a nested script or docker compose, is
# not seen and passes unchecked. Script paths resolve from $2, the repository
# root, or from the step's working-directory below it. Reads files only.
set -euo pipefail

workflow="${1:-.github/workflows/ci.yml}"
root="${2:-.}"
pull_script=.github/scripts/pull-mysql.sh

if [ ! -r "$workflow" ]; then
  printf '::error::cannot read %s to check the mysql:8 pull order\n' "$workflow" >&2
  exit 1
fi

# One record per step, in file order: job, name, working-directory and run
# text. Fields are split on octal 036, not a tab, because read collapses runs
# of whitespace separators and an empty field would vanish. Newlines in the
# run text become octal 037 so each record stays on one line.
steps_of() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function flush() {
      if (instep) printf "%s\036%s\036%s\036%s\n", job, name, wd, run
      instep = 0
    }
    { sub(/\r$/, "") }
    /^jobs:[ \t]*(#.*)?$/ { injobs = 1; next }
    injobs && /^[^ #]/ { flush(); injobs = 0 }
    !injobs { next }
    inrun {
      if ($0 ~ /^[ \t]*$/ || indent($0) > runkey) { run = run "\037" $0; next }
      inrun = 0
    }
    /^  [^ #]/ {
      flush(); job = $1; sub(/:.*/, "", job); insteps = 0; next
    }
    /^[ ]*steps:[ \t]*$/ { insteps = 1; stepsat = indent($0); dash = -1; next }
    !insteps || /^[ \t]*(#.*)?$/ { next }
    indent($0) <= stepsat && $0 !~ /^[ ]*- / { flush(); insteps = 0; next }
    /^[ ]*- / && (dash < 0 || indent($0) == dash) {
      flush(); dash = indent($0); instep = 1; name = ""; wd = ""; run = ""
      sub(/- /, "  ")
    }
    !instep { next }
    {
      line = $0; at = indent(line); sub(/^ */, "", line)
      if (line ~ /^name:/) { sub(/^name:[ \t]*/, "", line); name = line }
      else if (line ~ /^working-directory:/) { sub(/^working-directory:[ \t]*/, "", line); wd = line }
      else if (line ~ /^run:/) {
        sub(/^run:[ \t]*/, "", line)
        if (line ~ /^[|>]/) { inrun = 1; runkey = at } else run = line
      }
    }
    END { flush() }' "$1"
}

# Prints the run text and every script it hands to bash or sh, so one test
# sees what the step executes. Returns non-zero naming a script it cannot read.
text_of() {
  local run="$1" wd="$2" path
  printf '%s\n' "$run"
  while read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      /*) ;;
      *) path="$root/${wd:+$wd/}$path" ;;
    esac
    if [ ! -r "$path" ]; then
      printf '::error::%s: step runs %s, which cannot be read to tell whether it runs mysql:8\n' "$workflow" "$path" >&2
      return 1
    fi
    cat "$path"
  done < <(grep -oE '(^|[[:space:];&|(])(bash|sh)[[:space:]]+[^[:space:];&|)"'"'"']+' <<<"$run" |
    sed -E 's/^.*(bash|sh)[[:space:]]+//' | grep -v '^-' || true)
}

runs_mysql() {
  local code
  code="$(grep -vE '^[[:space:]]*#' || true)"
  grep -qE '(^|[^[:alnum:]_./-])mysql:8([^[:alnum:]_.:-]|$)' <<<"$code" &&
    grep -qiE 'docker\}?"?[[:space:]]+(container[[:space:]]+)?(run|create)([[:space:]]|$)' <<<"$code"
}

declare -A pulled=()
mysql_steps=0
bad=0
any_pull=0
while IFS=$'\036' read -r job name wd run; do
  run="${run//$'\037'/$'\n'}"
  if [[ "$run" == *"$pull_script"* ]]; then
    pulled[$job]=1
    any_pull=1
    continue
  fi
  text="$(text_of "$run" "$wd")"
  if ! runs_mysql <<<"$text"; then
    continue
  fi
  mysql_steps=$((mysql_steps + 1))
  if [ -z "${pulled[$job]:-}" ]; then
    printf "::error::%s: step '%s' runs mysql:8 before %s in job %s\n" "$workflow" "$name" "$pull_script" "$job" >&2
    bad=1
  else
    printf '  after the pull: %s\n' "$name"
  fi
done < <(steps_of "$workflow")

if [ "$mysql_steps" -eq 0 ]; then
  printf '::error::%s: found no step that runs mysql:8, so this check cannot tell a correct order from a workflow it failed to read\n' "$workflow" >&2
  exit 1
fi
if [ "$any_pull" -eq 0 ]; then
  printf '::error::%s: no step runs %s, so every mysql:8 self-test runs the cached image\n' "$workflow" "$pull_script" >&2
  exit 1
fi
if [ "$bad" -ne 0 ]; then
  exit 1
fi
printf 'the mysql:8 pull precedes all %d step(s) that run mysql:8\n' "$mysql_steps"
