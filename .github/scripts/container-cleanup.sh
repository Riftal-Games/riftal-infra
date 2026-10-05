#!/usr/bin/env bash
# Fails on any `docker run` without --rm and any `docker rm` without -v in the
# repo's shell scripts and workflows.
#
# mysql:8 declares VOLUME /var/lib/mysql, so every container started from it
# gets an anonymous volume that a plain `docker rm` leaves behind. The CI
# runners and every lane share one docker engine, where those volumes piled up
# by the thousand (riftal-infra#645). --rm also covers the run whose EXIT trap
# never fires: its container is removed with its volumes once it stops.
set -euo pipefail

root="${1:-.}"
prune="${2:-$root/.github/ci-fixtures}"

found="$(find "$root" \( -path "$root/.git" -o -path "$prune" -o -name node_modules \
  -o -name .venv \) -prune -o -type f \( -name '*.sh' \
  -o -path '*/.github/workflows/*.yml' -o -path '*/.github/workflows/*.yaml' \) -print)"
mapfile -t files < <(printf '%s' "$found")
printf 'found %d script(s) and workflow(s) outside the fixtures\n' "${#files[@]}"
if [ "${#files[@]}" -eq 0 ]; then
  exit 0
fi

# Backslash continuations are joined first, so a flag several lines below its
# `docker run` still counts. Each command is read up to the next `docker`, so
# a later command on the same line cannot lend it a flag.
awk '
  function check(cmd, at,    rest, seg, n) {
    rest = cmd
    while (match(rest, /docker[ \t]+(container[ \t]+)?(run|rm)([ \t]|$)/)) {
      seg = substr(rest, RSTART + 6)
      rest = seg
      n = match(seg, /[ \t]docker[ \t]/)
      if (n) seg = substr(seg, 1, n)
      seg = seg " "
      if (seg ~ /^[ \t]+(container[ \t]+)?run[ \t]/) {
        if (seg !~ /[ \t]--rm[ \t]/) {
          printf "%s:%d: a container started without --rm\n", FILENAME, at
          bad = 1
        }
      } else if (seg !~ /[ \t](--volumes|-[A-Za-z]*v[A-Za-z]*)[ \t]/) {
        printf "%s:%d: a container removed without -v\n", FILENAME, at
        bad = 1
      }
    }
  }
  FNR == 1 { cmd = ""; at = 0 }
  {
    line = $0
    if (cmd == "" && line ~ /^[ \t]*#/) next
    if (cmd == "") at = FNR
    if (line ~ /\\$/) {
      cmd = cmd substr(line, 1, length(line) - 1) " "
      next
    }
    check(cmd line, at)
    cmd = ""
  }
  END { exit bad }
' "${files[@]}"
