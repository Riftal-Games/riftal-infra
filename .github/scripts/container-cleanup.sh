#!/usr/bin/env bash
# Fails on any `docker run` or `docker create` without --rm and any `docker rm`
# without -v in the repo's shell scripts and workflows.
#
# mysql:8 declares VOLUME /var/lib/mysql, so every container started from it
# gets an anonymous volume that a plain `docker rm` leaves behind. The CI
# runners and every lane share one docker engine, so a volume one job leaves
# behind is disk that no later job on any lane gets back. --rm also covers the
# run whose EXIT trap never fires: its container is removed with its volumes
# once it stops.
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
# `docker run` still counts. A comment is dropped before the join, because the
# shell never passes it to docker. As in the shell, only a `#` outside quotes
# and after a blank starts one, so `"step #1"` and `$#` hide nothing.
# `$DOCKER`, `${DOCKER}` and their quoted forms are read as `docker`. Each command is read only up to the next `docker`
# or the next `;`, `&`, `&&`, `|` or `||`, so a later command on the same line
# cannot lend it a flag.
awk '
  function check(cmd, at,    rest, head, seg, n) {
    rest = cmd
    while (match(rest, /docker[ \t]+(container[ \t]+)?(run|rm|create)([ \t]|$)/)) {
      head = substr(rest, RSTART, RLENGTH)
      seg = substr(rest, RSTART + RLENGTH - 1)
      rest = seg
      n = match(seg, /[ \t]docker[ \t]/)
      if (n) seg = substr(seg, 1, n)
      n = match(seg, /[;&|]/)
      if (n) seg = substr(seg, 1, n - 1)
      seg = seg " "
      if (head !~ /rm[ \t]?$/) {
        if (seg !~ /[ \t]--rm[ \t]/) {
          printf "%s:%d: a container %s without --rm\n", FILENAME, at, (head ~ /create/ ? "created" : "started")
          bad = 1
        }
      } else if (seg !~ /[ \t](--volumes|-[A-Za-z]*v[A-Za-z]*)[ \t]/) {
        printf "%s:%d: a container removed without -v\n", FILENAME, at
        bad = 1
      }
    }
  }
  function uncomment(s,    i, c, q, prev) {
    q = ""
    prev = " "
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q == "" && c == "#" && prev ~ /[ \t]/) return substr(s, 1, i - 1)
      if (c == "\\" && q != "'\''") {
        i++
        prev = "x"
        continue
      }
      if (q == "" && (c == "\"" || c == "'\''")) q = c
      else if (c == q) q = ""
      prev = c
    }
    return s
  }
  FNR == 1 { cmd = ""; at = 0 }
  {
    line = uncomment($0)
    gsub(/"[$][{]DOCKER[}]"|"[$]DOCKER"|[$][{]DOCKER[}]|[$]DOCKER/, "docker", line)
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
