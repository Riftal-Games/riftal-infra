#!/usr/bin/env bash
# Fails on any `uses:` in a workflow or a composite action that names code by
# something that can move. A tag or a branch can be pointed at new code after
# the workflow naming it was reviewed and merged, and that code runs with the
# job's token. Three forms pass:
#
#   owner/repo[/path]@<40 hex>
#   ./path
#   docker://image@sha256:<64 hex>
#
# The first is a commit, in lowercase as git prints it. The second is an action
# in this same commit, and its own uses: lines are read here too, because
# action.yml files are discovered as well as workflows. The third is an image by
# content digest: a docker:// tag is refused for the same reason a git tag is.
#
# A quoted `"uses":` or `'uses':` key is read like a bare one. A `uses` key with
# a `[`, `{` or `,` before it on its line, as in `{ uses: ... }` or the
# single-pair `[ uses: ... ]`, fails whatever its value, because this script
# reads a value only where the key opens its line. A `uses:` that opens its own
# line inside a flow mapping spread over several lines is read that way, so a
# pinned value there passes, and a `,` or `}` after it fails.
#
# Some lines fail whatever they name, because they can spell a `uses` key that
# the reading above would miss: an explicit `?` key, where the `?` opens the
# line, follows a `-`, a tag or an anchor, or follows a `[`, `{` or `,`; a
# `uses` key behind a tag, an anchor or more than one `-`; an alias used as a
# key; and a double-quoted string with a backslash in it followed by a `:`,
# because an escape can spell `uses`. A key spelled any way not named in this
# header is not read.
#
# Any value other than the three forms fails, including one this script cannot
# read, so a value it does not know is reported rather than skipped. A `#`
# comment after the value is not part of it: `@<sha> # v4.4.0` passes, and a
# sha written only in the comment does not.
set -euo pipefail

root="${1:-.}"
prune="${2:-$root/.github/ci-fixtures}"

found="$(find "$root" \( -path "$root/.git" -o -path "$prune" -o -name node_modules \
  -o -name .venv \) -prune -o -type f \( -path '*/.github/workflows/*.yml' \
  -o -path '*/.github/workflows/*.yaml' -o -name action.yml -o -name action.yaml \) \
  -print0 | LC_ALL=C sort -z | tr '\0' '\n')"
mapfile -t files < <(printf '%s' "$found")
printf 'found %d workflow(s) and action(s) outside the fixtures\n' "${#files[@]}"

key="^[[:space:]]*(-[[:space:]]+)?(uses|\"uses\"|'uses')[[:space:]]*:(.*)\$"
# A line whose first non-blank character is `#` matches none of the patterns
# below that fail a line.
# Any `[`, `{` or `,` before a uses key on the same line fails the line,
# including one that opens it, so a bracket, brace or comma outside a flow
# collection is refused too. A tag, an anchor or a `?` between the two does not
# hide the key.
flow="^[[:space:]]*([^#[:space:]].*)?[[{,][[:space:]]*([-!&?][^[:space:]]*[[:space:]]*)*(uses|\"uses\"|'uses')[[:space:]]*:"
explicit="^[[:space:]]*(([^#[:space:]].*)?[[{,])?(([-!&][^[:space:]]*)?[[:space:]]+)*\?([[:space:]]|\$)"
# Group 1 is everything before the key: one `-` alone is an ordinary step.
decorated="^[[:space:]]*(([-!&][^[:space:]]*[[:space:]]*)+)(uses|\"uses\"|'uses')[[:space:]]*:"
alias_key="^[[:space:]]*([^#[:space:]].*)?(^|[[:space:][{,?-])\*[^][:space:],{}[]+[[:space:]]*:([[:space:]]|\$)"
escaped_key="^[[:space:]]*([^#[:space:]].*)?\"([^\"\\\\]|\\\\.)*\\\\([^\"\\\\]|\\\\.)*\"[[:space:]]*:"
double_quoted='^[[:space:]]*"([^"]*)"(.*)$'
single_quoted="^[[:space:]]*'([^']*)'(.*)\$"
plain='^[[:space:]]*([^[:space:]]*)(.*)$'
comment_only='^([[:space:]]+#.*)?[[:space:]]*$'
pinned='^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@[:space:]]+)?@[0-9a-f]{40}|\./[^@[:space:]]+|docker://[^@[:space:]]+@sha256:[0-9a-f]{64})$'

status=0
checked=0
for file in "${files[@]}"; do
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    if [[ $line =~ $flow ]]; then
      checked=$((checked + 1))
      printf '%s:%d: an action not pinned to a commit sha or image digest, in a flow mapping this script does not read: %s\n' \
        "$file" "$n" "${line#"${line%%[![:space:]]*}"}"
      status=1
      continue
    fi
    hidden=0
    [[ $line =~ $explicit || $line =~ $alias_key || $line =~ $escaped_key ]] && hidden=1
    if [[ $line =~ $decorated ]]; then
      prefix="${BASH_REMATCH[1]//[[:space:]]/}"
      [ "$prefix" = "-" ] || hidden=1
    fi
    if [ "$hidden" -eq 1 ]; then
      checked=$((checked + 1))
      printf '%s:%d: an action not pinned to a commit sha or image digest, behind a key form this script does not read: %s\n' \
        "$file" "$n" "${line#"${line%%[![:space:]]*}"}"
      status=1
      continue
    fi
    [[ $line =~ $key ]] || continue
    checked=$((checked + 1))
    rest="${BASH_REMATCH[3]}"
    [[ $rest =~ $double_quoted ]] || [[ $rest =~ $single_quoted ]] || [[ $rest =~ $plain ]]
    value="${BASH_REMATCH[1]}"
    after="${BASH_REMATCH[2]}"
    if ! [[ $after =~ $comment_only && $value =~ $pinned ]]; then
      printf '%s:%d: an action not pinned to a commit sha or image digest:%s\n' \
        "$file" "$n" "$rest"
      status=1
    fi
  done < "$file"
done
printf 'checked %d uses: line(s)\n' "$checked"
exit "$status"
