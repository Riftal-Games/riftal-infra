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
# reads a value only where the key opens its line. Such a key fails too with
# nothing after it on its line but blanks or a comment, as in `{ ?uses` with its
# `:` on the next line, which PyYAML reads as an explicit key. A `uses:` that
# opens its own line inside a flow mapping spread over several lines is read
# that way, so a pinned value there passes, and a `,` or `}` after it fails.
#
# Some lines fail whatever they name, because they can spell a `uses` key that
# the reading above would miss: an explicit `?` key, where a `?` followed by a
# space or the line's end opens the line or follows a `-`, a `[`, a `{` or a
# `,`; a `uses` key behind a tag, an anchor or more than one `-`; an alias used
# as a key; and a double-quoted key with an escape in it, because an escape can
# spell `uses`. A `?` after a tag or an anchor is not refused, because PyYAML
# rejects the file, in a block or a flow collection. The pattern misreads some
# keys holding an escaped `\` or `"`, such as `"a\\"`, and lets them pass:
# neither escape can be part of a key that spells `uses`.
#
# A line opening with a `?` and no space after it is refused when it spells a
# `uses` key, or a `uses` with nothing after it but blanks or a comment, and a
# line read before it ends in a `[`, a `{` or a `,`. That places the line inside
# a flow collection spread over several lines, where PyYAML reads any `?` as an
# explicit key. The lines read before it are the nearest one that is neither
# blank nor a comment, and every comment line after that one. Each is taken to
# end at its last character that is not a blank, and also at the last one
# before every blank followed by a `#`, because this script cannot tell a `#`
# opening a comment from one inside a quoted scalar, and a quoted scalar can
# run across lines. In a block the same line is a plain key `?uses` and passes,
# unless one of those ends is a `[`, a `{` or a `,`, which is refused: after a
# line ending in one of the three, a comment line or a trailing comment
# included, and after a line where one of them is followed by blanks and then a
# `#`, in a comment or in a quoted scalar. A key spelled any way not named in
# this header is not read.
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
# hide the key, even a `?` with no space after it: PyYAML reads `{ ?uses: x }`
# as an explicit key, and `{ ?uses` with its `:` on a later line as well, so a
# key with nothing after it but blanks or a comment is refused like one with a
# `:`.
flow="^[[:space:]]*([^#[:space:]].*)?[[{,][[:space:]]*([!&?][^[:space:]]*[[:space:]]*)*(uses|\"uses\"|'uses')([[:space:]]*(:|\$)|[[:space:]]+#)"
explicit="^[[:space:]]*(([^#[:space:]].*)?[[{,])?((-[^[:space:]]*)?[[:space:]]+)*\?([[:space:]]|\$)"
# Group 1 is everything before the key: one `-` alone is an ordinary step.
decorated="^[[:space:]]*(([-!&][^[:space:]]*[[:space:]]*)+)(uses|\"uses\"|'uses')[[:space:]]*:"
# An alias opening a line at column 0 is a key in a flow collection spread over
# several lines, whose continuation lines need no indent. A `?` with no space
# after it does not hide an alias: PyYAML reads `{ ?*k : x }` as an explicit key.
alias_key="^[[:space:]]*([^#[:space:]].*)?(^|[[:space:][{,?])\*[^][:space:],{}[]+[[:space:]]*:([[:space:]]|\$)"
continued_explicit="^[[:space:]]*\?([!&][^[:space:]]*[[:space:]]+)*(uses|\"uses\"|'uses')([[:space:]]*(:|\$)|[[:space:]]+#)"
blank_or_comment='^[[:space:]]*(#.*)?$'
escaped_key="^[[:space:]]*([^#[:space:]].*)?\"[^\"\\\\]*\\\\([^\"\\\\]|\\\\.)*\"[[:space:]]*:"
double_quoted='^[[:space:]]*"([^"]*)"(.*)$'
single_quoted="^[[:space:]]*'([^']*)'(.*)\$"
plain='^[[:space:]]*([^[:space:]]*)(.*)$'
comment_only='^([[:space:]]+#.*)?[[:space:]]*$'
pinned='^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@[:space:]]+)?@[0-9a-f]{40}|\./[^@[:space:]]+|docker://[^@[:space:]]+@sha256:[0-9a-f]{64})$'

status=0
checked=0
for file in "${files[@]}"; do
  n=0
  flow_open=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    in_flow=$flow_open
    ends_open=0
    code="$line"
    while :; do
      code="${code%"${code##*[![:space:]]}"}"
      [[ ${code: -1} == [[{,] ]] && ends_open=1
      [[ $code == *[[:space:]]#* ]] || break
      code="${code%[[:space:]]#*}"
    done
    if [[ $line =~ $blank_or_comment ]]; then
      [ "$ends_open" -eq 1 ] && flow_open=1
    else
      flow_open=$ends_open
    fi
    if [[ $line =~ $flow ]]; then
      checked=$((checked + 1))
      printf '%s:%d: an action not pinned to a commit sha or image digest, in a flow mapping this script does not read: %s\n' \
        "$file" "$n" "${line#"${line%%[![:space:]]*}"}"
      status=1
      continue
    fi
    hidden=0
    [[ $line =~ $explicit || $line =~ $alias_key || $line =~ $escaped_key ]] && hidden=1
    [[ $in_flow -eq 1 && $line =~ $continued_explicit ]] && hidden=1
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
