#!/usr/bin/env bash
# Fails on any `docker run` or `docker create` without --rm and any `docker rm`
# without -v in the repo's shell scripts and workflows.
#
# mysql:8 declares VOLUME /var/lib/mysql, so every container started from it
# gets an anonymous volume that a plain `docker rm` leaves behind. The CI
# runners and every lane share one docker engine, so a volume left behind by
# one job is disk the next job on any lane does not get back (riftal-infra#645).
# --rm also covers the run whose EXIT trap never fires: its container is
# removed with its volumes once it stops.
#
# A container that must outlive its process, such as a `--restart` service,
# cannot take --rm. It is admitted only under a comment on the line directly
# above it that gives the reason:
#
#   # container-cleanup: keep <why this container is long-lived>
#
# The opt-out covers that one command's missing --rm and nothing else. Its
# eventual `docker rm` still needs -v.
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
# `docker run` still counts. A trailing comment is dropped, and each command is
# read only up to the next `docker` or shell separator, so neither a comment
# nor a later command on the same line can lend it a flag. `$DOCKER` and
# `${DOCKER}` count as docker.
awk '
  BEGIN {
    dk = "(docker|\"?[$][{]?DOCKER[}]?\"?)"
    verb = dk "[ \t]+(container[ \t]+)?(run|rm|create)([ \t]|$)"
    next_dk = "[ \t]" dk "[ \t]"
    sep = "(;|&&|[|]|&[ \t]|&$)"
  }
  function report(at, what) {
    printf "%s:%d: %s\n", FILENAME, at, what
    bad = 1
  }
  function check(cmd, at,    rest, head, seg, n, kept) {
    kept = 0
    rest = cmd
    while (match(rest, verb)) {
      head = substr(rest, RSTART, RLENGTH)
      seg = substr(rest, RSTART + RLENGTH)
      rest = seg
      n = match(seg, next_dk)
      if (n) seg = substr(seg, 1, n)
      n = match(seg, sep)
      if (n) seg = substr(seg, 1, n - 1)
      seg = " " seg " "
      if (head ~ /(run|create)[ \t]*$/) {
        if (seg ~ /[ \t]--rm[ \t]/) continue
        if (keep_at && !kept) {
          kept = 1
        } else if (head ~ /run[ \t]*$/) {
          report(at, "a container started without --rm")
        } else {
          report(at, "a container created without --rm")
        }
      } else if (seg !~ /[ \t](--volumes|-[A-Za-z]*v[A-Za-z]*)[ \t]/) {
        report(at, "a container removed without -v")
      }
    }
    if (keep_at && !kept) report(keep_at, "a container-cleanup opt-out with no container under it to keep")
    keep_at = 0
  }
  FNR == 1 { cmd = ""; at = 0; keep_at = 0 }
  {
    line = $0
    if (cmd == "" && line ~ /^[ \t]*#/) {
      if (line ~ /^[ \t]*#[ \t]*container-cleanup:/) {
        if (line ~ /^[ \t]*#[ \t]*container-cleanup:[ \t]*keep[ \t]+[^ \t]/) {
          keep_at = FNR
        } else {
          report(FNR, "a container-cleanup opt-out without a reason")
        }
      }
      next
    }
    sub(/(^|[ \t])#.*$/, "", line)
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
