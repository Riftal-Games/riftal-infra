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
#
# A container that must outlive its process, such as a `--restart` service,
# cannot take --rm. It is admitted only under a whole comment line directly
# above it that gives the reason:
#
#   # container-cleanup: keep <why this container is long-lived>
#
# That excuses the missing --rm of the command that opens the line below it
# and nothing else: not a second command on that line, not its later
# `docker rm`, which still needs -v. An opt-out that excuses nothing is itself reported, so one
# can never be left waiting for whatever command is written under it next.
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
# `docker run` still counts. `$DOCKER`, `${DOCKER}` and their quoted forms are
# read as `docker`. Each command is read only up to the next `docker` or the
# next `;`, `&`, `&&`, `|` or `||`, so a later command on the same line cannot
# lend it a flag.
awk '
  # keep_file is the file the pending opt-out was read in, which FILENAME no
  # longer names once the next file has started.
  function drop_keep() {
    if (keep_at) {
      printf "%s:%d: a container-cleanup opt-out with no container under it to keep\n", keep_file, keep_at
      bad = 1
    }
    keep_at = 0
  }
  # A command still continued when its file ends is checked as it stands, so a
  # backslash on a last line cannot hide a run from the next file or from END.
  function flush() {
    if (cmd != "") check(cmd, at, at_file)
    cmd = ""
  }
  function check(cmd, at, file,    rest, head, seg, n) {
    rest = cmd
    while (match(rest, /docker[ \t]+(container[ \t]+)?(run|rm|create)([ \t]|$)/)) {
      if (substr(rest, 1, RSTART - 1) !~ /^[ \t]*$/) drop_keep()
      head = substr(rest, RSTART, RLENGTH)
      seg = substr(rest, RSTART + RLENGTH - 1)
      rest = seg
      n = match(seg, /[ \t]docker[ \t]/)
      if (n) seg = substr(seg, 1, n)
      n = match(seg, /[;&|]/)
      if (n) seg = substr(seg, 1, n - 1)
      # Any # may open a trailing comment, and telling a quoted or $# one
      # apart takes a shell parser, so no flag after the first # counts. That
      # can report a command whose flag follows a quoted #, and it never
      # hides one: the cut only narrows where a flag is looked for, never
      # where a command is. The # itself stays, so a word such as --rm# does
      # not end on a blank and is not read as the flag.
      n = index(seg, "#")
      if (n) seg = substr(seg, 1, n)
      seg = seg " "
      if (head !~ /rm[ \t]?$/) {
        if (seg !~ /[ \t]--rm[ \t]/) {
          if (keep_at) {
            keep_at = 0
          } else {
            printf "%s:%d: a container %s without --rm\n", file, at, (head ~ /create/ ? "created" : "started")
            bad = 1
          }
        }
      } else if (seg !~ /[ \t](--volumes|-[A-Za-z]*v[A-Za-z]*)[ \t]/) {
        printf "%s:%d: a container removed without -v\n", file, at
        bad = 1
      }
    }
    drop_keep()
  }
  FNR == 1 { flush(); drop_keep(); at = 0 }
  {
    line = $0
    if (cmd == "" && line ~ /^[ \t]*#/) {
      drop_keep()
      if (sub(/^[ \t]*# container-cleanup:/, "", line)) {
        if (line ~ /^ keep[ \t]+[^ \t]/) {
          keep_at = FNR
          keep_file = FILENAME
        } else {
          printf "%s:%d: a container-cleanup line that is not keep <reason>\n", FILENAME, FNR
          bad = 1
        }
      }
      next
    }
    gsub(/"[$][{]DOCKER[}]"|"[$]DOCKER"|[$][{]DOCKER[}]|[$]DOCKER/, "docker", line)
    if (cmd == "") {
      at = FNR
      at_file = FILENAME
    }
    if (line ~ /\\$/) {
      cmd = cmd substr(line, 1, length(line) - 1) " "
      next
    }
    check(cmd line, at, FILENAME)
    cmd = ""
  }
  END { flush(); drop_keep(); exit bad }
' "${files[@]}"
