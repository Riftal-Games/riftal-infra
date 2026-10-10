#!/usr/bin/env bash
# Fails unless, in every job of the workflow at $1, the pull step comes before
# every step that runs mysql:8 (riftal-infra#962). A self-test that starts
# mysql:8 ahead of the pull runs the runner's cached copy of a floating tag,
# and CI stays green while it does.
#
# The pull step is one whose whole run text, full-line comments dropped, is
# `bash .github/scripts/pull-mysql.sh`, with no if: and no continue-on-error:
# other than false, since either can let the job go on without a pull. Its
# own text, script included, must not run mysql:8. Any other step that names
# that path fails the check and is still checked for running mysql:8 itself.
# A mysql:8 step after the pull fails when its if: calls always(), failure()
# or cancelled(), since those run it when the pull has failed.
#
# A step runs mysql:8 when it is `uses: docker://` with a mysql:8 image, or
# when its text, full-line comments dropped, both names mysql:8 as its own
# token, after any registry or namespace path, and starts a container. A start
# is docker, podman or nerdctl, by any path and in any case, or a shell
# variable, then any closing } and ", then any global flags, then run, create
# or container run|create; or any compose up, run, create or start, which
# counts whatever it names, since the compose file is not read. A line ending
# in \ joins the next, and the words between compose and its verb stop at ;,
# & or |, which end the compose command. The name and the start are tested
# separately over the whole text, so a trailing comment can flag a step that
# does neither.
#
# A step's text is its run text, every env: in scope at step, job and
# workflow level, and every script the run text names: a word ending in .sh,
# a word starting ./ or ../ as a command, the operand of . or source, and the
# first operand of a bash or sh command after its flags and any --rcfile
# argument, unless -c is one of them, or -n, which parses without running.
# An unquoted glob reads every file it matches. Each is read one level deep:
# a script that starts another script is not followed. A relative path
# resolves from $2, the repository root, joined with the step's
# working-directory, its quotes and trailing comment dropped.
#
# What it cannot place, it refuses rather than skips: a job-level services:
# or container:, a working-directory: outside a step as under defaults:, a
# steps: key with a value on its line, a job indented less than the first, a
# run that has cd or pushd as a word anywhere, inside bash -c included, and
# names a relative script, a script named through a variable or a quoted
# glob, and a script it cannot read. Reads files only. A step with no name:
# is reported as #N, its place in its job.
set -euo pipefail

workflow="${1:-.github/workflows/ci.yml}"
root="${2:-.}"
pull_script=.github/scripts/pull-mysql.sh

if [ ! -r "$workflow" ]; then
  printf '::error::cannot read %s to check the mysql:8 pull order\n' "$workflow" >&2
  exit 1
fi

# One record per step, in file order: kind S, job, name, working-directory,
# the keys that make a step conditional, a docker:// image, run text, the if:
# expression, and every env: in scope, step, job and workflow. A shape this
# cannot place is a record of kind E carrying its reason. Fields are split on
# octal 036, not a tab, because read collapses runs of whitespace separators
# and an empty field would vanish. Newlines become octal 037 so each record
# stays on one line. Records print at the end, since a job's or the
# workflow's env: can follow the steps it applies to.
steps_of() {
  awk -v q="'" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function flush() {
      if (instep) {
        if (name == "") name = "#" stepno
        rec[++n] = "S\036" job "\036" name "\036" wd "\036" cond "\036" image "\036" run "\036" ifx "\036" senv
        recjob[n] = job
      }
      instep = 0
    }
    function refuse(why) { rec[++n] = "E\036line " NR ": " why }
    # Quotes and a trailing comment are YAML around the value, not part of it.
    function scalar(s) {
      if (s ~ /^"/) { sub(/^"/, "", s); sub(/".*/, "", s); return s }
      if (s ~ ("^" q)) { sub("^" q, "", s); sub(q ".*", "", s); return s }
      sub(/[ \t]+#.*/, "", s); sub(/[ \t]+$/, "", s); return s
    }
    # A run scalar that is not a literal | block folds its lines into one
    # command, so those join with a space.
    function more(s) {
      if (cont == "run") run = run sep s
      else if (cont == "if") ifx = ifx " " s
      else if (cont == "senv") senv = senv "\037" s
      else if (cont == "jenv") jenv[job] = jenv[job] "\037" s
      else wenv = wenv "\037" s
    }
    { sub(/\r$/, "") }
    cont != "" {
      if ($0 ~ /^[ \t]*$/ || indent($0) > contat) { more($0); next }
      cont = ""
    }
    /^[ \t]*(#.*)?$/ { next }
    /^jobs:[ \t]*(#.*)?$/ { injobs = 1; jobat = -1; next }
    /^[^ ]/ { flush(); injobs = 0; insteps = 0 }
    /^env:/ { e = $0; sub(/^env:[ \t]*/, "", e); wenv = wenv "\037" e; cont = "wenv"; contat = 0; next }
    insteps && indent($0) <= stepsat && $0 !~ /^[ ]*- / { flush(); insteps = 0 }
    !insteps && /^[ \t]*working-directory:/ { refuse("a working-directory: outside a step, as under defaults:, is not read"); next }
    !injobs { next }
    jobat < 0 { jobat = indent($0) }
    indent($0) < jobat { refuse("a line indented less than the first job"); next }
    indent($0) == jobat { flush(); job = $1; sub(/:.*/, "", job); insteps = 0; next }
    !insteps && /^[ ]*(services|container):/ {
      refuse("job " job " sets services: or container:, which starts before any step"); next
    }
    !insteps && /^[ ]*env:/ {
      e = $0; contat = indent(e); sub(/^[ ]*env:[ \t]*/, "", e); jenv[job] = jenv[job] "\037" e; cont = "jenv"; next
    }
    !insteps && /^[ ]*steps:/ {
      if ($0 !~ /^[ ]*steps:[ \t]*(#.*)?$/) { refuse("a steps: key with a value on its line"); next }
      insteps = 1; stepsat = indent($0); dash = -1; stepno = 0; next
    }
    !insteps { next }
    /^[ ]*- / && (dash < 0 || indent($0) == dash) {
      flush(); dash = indent($0); instep = 1; stepno++; name = ""; wd = ""; cond = ""; image = ""; run = ""; ifx = ""; senv = ""
      sub(/- /, "  ")
    }
    !instep { next }
    {
      line = $0; at = indent(line); sub(/^ */, "", line)
      if (line ~ /^name:/) { sub(/^name:[ \t]*/, "", line); name = scalar(line) }
      else if (line ~ /^working-directory:/) { sub(/^working-directory:[ \t]*/, "", line); wd = scalar(line) }
      else if (line ~ /^if:/) { cond = cond " if:"; sub(/^if:[ \t]*/, "", line); ifx = line; cont = "if"; contat = at }
      else if (line ~ /^env:/) { sub(/^env:[ \t]*/, "", line); senv = line; cont = "senv"; contat = at }
      else if (line ~ /^continue-on-error:/ && line !~ /^continue-on-error:[ \t]*false[ \t]*(#.*)?$/) {
        cond = cond " continue-on-error:"
      }
      else if (line ~ ("^uses:[ \t]*[\"" q "]?docker://")) { sub("^uses:[ \t]*[\"" q "]?docker://", "", line); image = line }
      else if (line ~ /^run:/) {
        sub(/^run:[ \t]*/, "", line)
        sep = line ~ /^\|/ ? "\037" : " "
        run = line ~ /^[|>]/ ? "" : line
        cont = "run"; contat = at
      }
    }
    END {
      flush()
      for (i = 1; i <= n; i++) print rec[i] (rec[i] ~ /^S/ ? "\037" jenv[recjob[i]] "\037" wenv : "")
    }' "$1"
}

glob='[*?[]'

# Prints a script word with its quotes dropped. A variable, or a glob inside
# quotes that the shell may pass on unexpanded, names nothing this check can
# read, so it prints as a refusal line instead.
script_word() {
  local word="${1//[\"\']/}"
  if [[ "$word" == *'$'* ]] || { [[ "$1" == *[\"\']* ]] && [[ "$word" == *$glob* ]]; }; then
    printf '\tvar %s\n' "$word"
  else
    printf '%s\n' "$word"
  fi
}

# Prints each script the run text names, one per line.
scripts_of() {
  local code seg word i noexec
  local -a w
  code="$(grep -vE '^[[:space:]]*#' <<<"$1" || true)"
  while IFS= read -r word; do
    script_word "$word"
  done < <(grep -oE "[^[:space:]=<>;&|()]+\.sh([^[:alnum:]_.-]|\$)" <<<"$code" | sed -E 's/\.sh.$/.sh/' || true)
  while IFS= read -r seg; do
    read -ra w <<<"${seg//[\"\']/}" || true
    # Any word, not only the command word, since bash -c, sudo or a wrapper
    # this loop does not know can put the cd behind other words.
    for word in "${w[@]}"; do
      [[ "$word" != cd && "$word" != pushd ]] || printf '\tcd\n'
    done
    i=0
    while [ "$i" -lt "${#w[@]}" ] &&
      [[ "${w[i]}" =~ ^(exec|sudo|env|time|nohup|command|builtin|then|do|else|if|while|until|!|\{|timeout|-.*|[[:alpha:]_][[:alnum:]_]*=.*|[0-9][0-9.]*[smhd]?)$ ]]; do
      i=$((i + 1))
    done
    word="${w[i]:-}"
    case "$word" in
      ./* | ../*) script_word "$word" ;;
      . | source) [ -z "${w[i + 1]:-}" ] || script_word "${w[i + 1]}" ;;
      bash | sh)
        noexec=
        for ((i = i + 1; i < ${#w[@]}; i++)); do
          [[ ! "${w[i]}" =~ ^-[^-]*n ]] || noexec=1
          case "${w[i]}" in
            --rcfile | --init-file) i=$((i + 1)) ;;
            --*) ;;
            -*c*) break ;;
            [-+]*[oO]) i=$((i + 1)) ;;
            -* | +*) ;;
            *)
              [ -n "$noexec" ] || script_word "${w[i]}"
              break
              ;;
          esac
        done
        ;;
    esac
  done < <(sed -E 's/(&&|\|\||[;&|(])/\n/g' <<<"$code")
}

# Prints the run text and every script it names, so one test sees what the
# step executes. Returns non-zero naming a script it cannot read, or a run
# that changes directory and then names a relative script, since that script
# would be resolved from the wrong place.
text_of() {
  local run="$1" wd="$2" name="$3" path scripts unresolved files file
  scripts="$(scripts_of "$run" | sort -u)"
  unresolved="$(grep -m1 $'^\tvar ' <<<"$scripts" || true)"
  if [ -n "$unresolved" ]; then
    printf "::error::%s: step '%s' names a script through a variable or a quoted glob, %s, which this check cannot resolve\n" \
      "$workflow" "$name" "${unresolved#$'\tvar '}" >&2
    return 1
  fi
  if grep -qx $'\tcd' <<<"$scripts" && grep -qv -e '^/' -e $'^\tcd$' <<<"$scripts"; then
    printf "::error::%s: step '%s' changes directory before running a relative script, which this check cannot resolve; set working-directory: instead\n" \
      "$workflow" "$name" >&2
    return 1
  fi
  printf '%s\n' "$run"
  while IFS= read -r path; do
    [ -n "$path" ] && [ "$path" != $'\tcd' ] || continue
    case "$path" in
      /*) ;;
      *) path="$root/${wd:+$wd/}$path" ;;
    esac
    files="$path"
    [[ "$path" != *$glob* ]] || files="$(compgen -G "$path" || printf '%s' "$path")"
    while IFS= read -r file; do
      if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        printf '::error::%s: step runs %s, which cannot be read to tell whether it runs mysql:8\n' "$workflow" "$file" >&2
        return 1
      fi
      cat "$file"
    done <<<"$files"
  done <<<"$scripts"
}

mysql_ref='(^|[^[:alnum:]_.-])([[:alnum:]._-]+(:[0-9]+)?/)*mysql:8([^[:alnum:]_.:-]|$)'
engine='(^|[^[:alnum:]_.$-])([^[:space:]]*/)?(docker|podman|nerdctl)|\$\{?[[:alpha:]_][[:alnum:]_]*'
flag='[[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?'
start="($engine)[}\"]*($flag)*[[:space:]]+(container[[:space:]]+)?(run|create)([[:space:]]|\$)"
compose="($engine)[}\"]*([[:blank:]]+|-)compose([[:blank:]]+[^[:space:];&|]+)*[[:blank:]]+(up|run|create|start)([[:space:]]|\$)"

runs_mysql() {
  local code
  code="$(grep -vE '^[[:space:]]*#' | tr -d '\r' | sed -E ':a;/\\$/{N;s/\\\n//;ba}' || true)"
  grep -qiE "$compose" <<<"$code" ||
    { grep -qE "$mysql_ref" <<<"$code" && grep -qiE "$start" <<<"$code"; }
}

declare -A pulled=()
mysql_steps=0
bad=0
any_pull=0
while IFS=$'\036' read -r kind job name wd cond image run ifx env; do
  if [ "$kind" = E ]; then
    printf '::error::%s: %s, so this check cannot place it against the pull\n' "$workflow" "$job" >&2
    bad=1
    continue
  fi
  run="${run//$'\037'/$'\n'}"
  env="${env//$'\037'/$'\n'}"
  code="$(grep -vE '^[[:space:]]*#' <<<"$run" || true)"
  if [[ "$code" =~ ^[[:space:]]*bash[[:space:]]+\.github/scripts/pull-mysql\.sh[[:space:]]*$ ]]; then
    if [ -n "$cond" ]; then
      printf "::error::%s: pull step '%s' sets%s, so the job can go on without the pull\n" "$workflow" "$name" "$cond" >&2
      bad=1
    fi
    text="$(text_of "$run" "$wd" "$name")"
    if runs_mysql <<<"$text"$'\n'"$env"; then
      printf "::error::%s: pull step '%s' runs mysql:8 itself, before or without the pull it exists to make\n" "$workflow" "$name" >&2
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
    probe="$image"
    [[ "$image" != *'${{'* ]] || probe+=$'\n'"$env"
    grep -qE "$mysql_ref" <<<"$probe" || continue
  else
    text="$(text_of "$run" "$wd" "$name")"
    runs_mysql <<<"$text"$'\n'"$env" || continue
  fi
  mysql_steps=$((mysql_steps + 1))
  if [ -z "${pulled[$job]:-}" ]; then
    printf "::error::%s: step '%s' runs mysql:8 before %s in job %s\n" "$workflow" "$name" "$pull_script" "$job" >&2
    bad=1
  elif [[ "${ifx,,}" =~ (always|failure|cancelled)[[:space:]]*\( ]]; then
    printf "::error::%s: step '%s' runs mysql:8 under if: %s, which runs it when the pull has failed\n" \
      "$workflow" "$name" "$ifx" >&2
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
