#!/usr/bin/env bash
# Fails unless, in every job of the workflow at $1, the pull step comes before
# every step that runs mysql:8 (riftal-infra#962). A self-test that starts
# mysql:8 ahead of the pull runs the runner's cached copy of a floating tag,
# and CI stays green while it does.
#
# The pull step is one whose whole run text, comments dropped, is
# `bash .github/scripts/pull-mysql.sh`, with no if: and no continue-on-error:
# other than false, since either can let the job go on without a pull. Any
# other step that names that path fails the check and is still checked for
# running mysql:8 itself.
#
# A step runs mysql:8 when it is `uses: docker://` with a mysql:8 image, or
# when its text, full-line comments dropped, both names mysql:8 as its own
# token, after any registry or namespace path, and starts a container. A start
# is docker, podman or nerdctl, by any path and in any case, or a shell
# variable, then any closing } and ", then any global flags, then run, create
# or container run|create; or any compose up, run, create or start, which
# counts whatever it names, since the compose file is not read. The name and
# the start are tested separately over the whole text, so a trailing comment
# can flag a step that does neither.
#
# A step's text is its run text plus every script that text names: a word
# ending in .sh, a word starting ./ or ../ as a command, and the first operand
# of a bash or sh command after its flags, unless -c is one of them. Each is
# read one level deep: a script that starts another script is not followed.
# A relative path resolves from $2, the repository root, joined with the
# step's working-directory.
#
# What it cannot place, it refuses rather than skips: a job-level services:
# or container:, a working-directory: outside a step as under defaults:, a
# steps: key with a value on its line, a job indented less than the first,
# and a script it cannot read. Reads files only.
set -euo pipefail

workflow="${1:-.github/workflows/ci.yml}"
root="${2:-.}"
pull_script=.github/scripts/pull-mysql.sh

if [ ! -r "$workflow" ]; then
  printf '::error::cannot read %s to check the mysql:8 pull order\n' "$workflow" >&2
  exit 1
fi

# One record per step, in file order: kind S, job, name, working-directory,
# the keys that make a step conditional, a docker:// image, and run text. A
# shape this cannot place is a record of kind E carrying its reason. Fields
# are split on octal 036, not a tab, because read collapses runs of whitespace
# separators and an empty field would vanish. Newlines in the run text become
# octal 037 so each record stays on one line.
steps_of() {
  awk -v q="'" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function flush() {
      if (instep) printf "S\036%s\036%s\036%s\036%s\036%s\036%s\n", job, name, wd, cond, image, run
      instep = 0
    }
    function refuse(why) { printf "E\036line %d: %s\n", NR, why }
    { sub(/\r$/, "") }
    inrun {
      if ($0 ~ /^[ \t]*$/ || indent($0) > runkey) { run = run "\037" $0; next }
      inrun = 0
    }
    /^[ \t]*(#.*)?$/ { next }
    /^jobs:[ \t]*(#.*)?$/ { injobs = 1; jobat = -1; next }
    /^[^ ]/ { flush(); injobs = 0; insteps = 0 }
    insteps && indent($0) <= stepsat && $0 !~ /^[ ]*- / { flush(); insteps = 0 }
    !insteps && /^[ \t]*working-directory:/ { refuse("a working-directory: outside a step, as under defaults:, is not read"); next }
    !injobs { next }
    jobat < 0 { jobat = indent($0) }
    indent($0) < jobat { refuse("a line indented less than the first job"); next }
    indent($0) == jobat { flush(); job = $1; sub(/:.*/, "", job); insteps = 0; next }
    !insteps && /^[ ]*(services|container):/ {
      refuse("job " job " sets services: or container:, which starts before any step"); next
    }
    !insteps && /^[ ]*steps:/ {
      if ($0 !~ /^[ ]*steps:[ \t]*(#.*)?$/) { refuse("a steps: key with a value on its line"); next }
      insteps = 1; stepsat = indent($0); dash = -1; next
    }
    !insteps { next }
    /^[ ]*- / && (dash < 0 || indent($0) == dash) {
      flush(); dash = indent($0); instep = 1; name = ""; wd = ""; cond = ""; image = ""; run = ""
      sub(/- /, "  ")
    }
    !instep { next }
    {
      line = $0; at = indent(line); sub(/^ */, "", line)
      if (line ~ /^name:/) { sub(/^name:[ \t]*/, "", line); name = line }
      else if (line ~ /^working-directory:/) { sub(/^working-directory:[ \t]*/, "", line); wd = line }
      else if (line ~ /^if:/) cond = cond " if:"
      else if (line ~ /^continue-on-error:/ && line !~ /^continue-on-error:[ \t]*false[ \t]*(#.*)?$/) {
        cond = cond " continue-on-error:"
      }
      else if (line ~ ("^uses:[ \t]*[\"" q "]?docker://")) { sub("^uses:[ \t]*[\"" q "]?docker://", "", line); image = line }
      else if (line ~ /^run:/) {
        sub(/^run:[ \t]*/, "", line)
        if (line ~ /^[|>]/) { inrun = 1; runkey = at } else run = line
      }
    }
    END { flush() }' "$1"
}

# Prints each script the run text names, one per line.
scripts_of() {
  local code seg word i
  local -a w
  code="$(grep -vE '^[[:space:]]*#' <<<"$1" || true)"
  grep -oE "[^[:space:]\"'=<>;&|()]+\.sh([^[:alnum:]_.-]|\$)" <<<"$code" | sed -E 's/\.sh.$/.sh/' || true
  while IFS= read -r seg; do
    read -ra w <<<"$seg" || true
    i=0
    while [ "$i" -lt "${#w[@]}" ] &&
      [[ "${w[i]}" =~ ^(exec|sudo|env|time|nohup|then|do|else|if|while|until|!|timeout|[[:alpha:]_][[:alnum:]_]*=.*|[0-9.]+[smhd]?)$ ]]; do
      i=$((i + 1))
    done
    word="${w[i]:-}"
    word="${word//[\"\']/}"
    case "$word" in
      ./* | ../*) printf '%s\n' "$word" ;;
      bash | sh)
        for ((i = i + 1; i < ${#w[@]}; i++)); do
          case "${w[i]}" in
            --*) ;;
            -*c*) break ;;
            [-+]*[oO]) i=$((i + 1)) ;;
            -*) ;;
            *)
              printf '%s\n' "${w[i]//[\"\']/}"
              break
              ;;
          esac
        done
        ;;
    esac
  done < <(sed -E 's/(&&|\|\||[;&|(])/\n/g' <<<"$code")
}

# Prints the run text and every script it names, so one test sees what the
# step executes. Returns non-zero naming a script it cannot read.
text_of() {
  local run="$1" wd="$2" path
  printf '%s\n' "$run"
  while read -r path; do
    case "$path" in
      /*) ;;
      *) path="$root/${wd:+$wd/}$path" ;;
    esac
    if [ ! -f "$path" ] || [ ! -r "$path" ]; then
      printf '::error::%s: step runs %s, which cannot be read to tell whether it runs mysql:8\n' "$workflow" "$path" >&2
      return 1
    fi
    cat "$path"
  done < <(scripts_of "$run" | sort -u)
}

mysql_ref='(^|[^[:alnum:]_.-])([[:alnum:]._-]+(:[0-9]+)?/)*mysql:8([^[:alnum:]_.:-]|$)'
engine='(^|[^[:alnum:]_.$-])([^[:space:]]*/)?(docker|podman|nerdctl)|\$\{?[[:alpha:]_][[:alnum:]_]*'
flag='[[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?'
start="($engine)[}\"]*($flag)*[[:space:]]+(container[[:space:]]+)?(run|create)([[:space:]]|\$)"
compose="($engine)[}\"]*([[:space:]]+|-)compose([[:space:]]+[^[:space:]]+)*[[:space:]]+(up|run|create|start)([[:space:]]|\$)"

runs_mysql() {
  local code
  code="$(grep -vE '^[[:space:]]*#' || true)"
  grep -qiE "$compose" <<<"$code" ||
    { grep -qE "$mysql_ref" <<<"$code" && grep -qiE "$start" <<<"$code"; }
}

declare -A pulled=()
mysql_steps=0
bad=0
any_pull=0
while IFS=$'\036' read -r kind job name wd cond image run; do
  if [ "$kind" = E ]; then
    printf '::error::%s: %s, so this check cannot place it against the pull\n' "$workflow" "$job" >&2
    bad=1
    continue
  fi
  run="${run//$'\037'/$'\n'}"
  code="$(grep -vE '^[[:space:]]*#' <<<"$run" || true)"
  if [[ "$code" =~ ^[[:space:]]*bash[[:space:]]+\.github/scripts/pull-mysql\.sh[[:space:]]*$ ]]; then
    if [ -n "$cond" ]; then
      printf "::error::%s: pull step '%s' sets%s, so the job can go on without the pull\n" "$workflow" "$name" "$cond" >&2
      bad=1
    fi
    pulled[$job]=1
    any_pull=1
    continue
  fi
  if [[ "$run" == *"$pull_script"* ]]; then
    printf "::error::%s: step '%s' names %s but is not the plain step bash %s, so it is not counted as the pull\n" \
      "$workflow" "$name" "$pull_script" "$pull_script" >&2
    bad=1
  fi
  if [ -n "$image" ]; then
    grep -qE "$mysql_ref" <<<"$image" || continue
  else
    text="$(text_of "$run" "$wd")"
    runs_mysql <<<"$text" || continue
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
