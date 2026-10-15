#!/usr/bin/env bash
# Prints every shell script under a root, one per line: a .sh or .bash file, or
# a file with no extension whose first line is a shebang naming a shell. The
# script a deploy runs is the one most likely to have no extension.
#
# Usage: list_shell.sh <root> [prune-path]
set -euo pipefail

root="${1:-.}"
prune="${2:-$root/.git}"
shebang='^#!.*[/ ](ba|da|k|z|a)?sh([[:space:]]|$)'

while IFS= read -r -d '' file; do
  case "${file##*/}" in
    *.sh | *.bash) ;;
    *.*) continue ;;
    *) first='' && { IFS= read -r first <"$file" || true; } && [[ $first =~ $shebang ]] || continue ;;
  esac
  printf '%s\n' "$file"
done < <(find "$root" -path "$root/.git" -prune -o -path "$prune" -prune -o -type f -print0 |
  LC_ALL=C sort -z)
