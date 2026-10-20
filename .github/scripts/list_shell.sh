#!/usr/bin/env bash
# Prints every shell script under a root, one per line: a .sh file in any
# case, a .bash, .zsh or .ksh file, or a file of any other name, dotted or not,
# whose first line is a shebang naming a program that ends in sh. That takes in
# fish, zsh and pwsh as well, because a script this cannot tell is a shell is
# one it cannot clear. The script a deploy runs is the one most likely to have
# an odd name.
#
# Usage: list_shell.sh <root> [prune-path]
set -euo pipefail

root="${1:-.}"
prune="${2:-$root/.git}"
shebang='^#!.*[/ ][a-z]*sh([[:space:]]|$)'

while IFS= read -r -d '' file; do
  case "${file##*/}" in
    *.[sS][hH] | *.bash | *.zsh | *.ksh) ;;
    *) first='' && { IFS= read -r -n 256 first <"$file" || true; } && [[ $first =~ $shebang ]] || continue ;;
  esac
  printf '%s\n' "$file"
done < <(find "$root" -path "$root/.git" -prune -o -path "$prune" -prune -o -type f -print0 |
  LC_ALL=C sort -z)
