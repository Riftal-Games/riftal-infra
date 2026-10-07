#!/usr/bin/env bash
# Fails on every line under .github/workflows and .github/scripts whose text
# names docker in any letter case, unless that line is one of:
#   - one plain `docker run` or `docker create` with -m/--memory and --cpus
#     ahead of its image;
#   - a command on a short allowlist that starts no container, alone, or as
#     the whole of name="$(...)", with only redirects to /dev/null and a final
#     || true, || continue, || exit 1 or \ after it;
#   - a comment with no quote, no command substitution and no backquoted span
#     but the bare words problem() names below;
#   - directly below `# container-limits: exempt <reason>`.
# The trigger is the text, not a parse, so a line that matches none of these is
# reported however it names docker: an operator, a command substitution, a
# variable or quoted word as docker or its verb, compose and global options all
# fail. A workflow container:, services: or docker:// image runs where no -m or
# --cpus reaches, so a workflow key naming one is reported too.
#
# Accepted residual (riftal-infra#811): docker reached by a line that does not
# name it, such as $d run where d comes from the environment.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  set -- .github/workflows .github/scripts
fi
# A missing path fails find, so one absent directory cannot shrink the scope
# to the rest and still pass.
if ! files="$(find "$@" -type f | sort)" || [ -z "$files" ]; then
  printf '::error::a missing path, or no file to check, under %s\n' "$*"
  exit 1
fi

# File names hold no newline in this repository, and a name that did would be
# reported as missing by awk rather than skipped.
mapfile -t list <<<"$files"
awk '
function report(f, l, m) { print f ":" l ": " m; bad = 1 }
function take(  ) {
  sub(/^[ \t]+/, "", rest)
  if (rest == "") return 0
  if (match(rest, /^[12]?>(\/dev\/null|&[12])/) || match(rest, /^[A-Za-z0-9_.\/:@=,+%^-]+/) ||
      match(rest, /^\047[^\047]*\047/) ||
      match(rest, /^"([^"$\\`]|\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*(\[@\])?\}|\$[0-9@]|\\\$)*"/)) {
    tok = substr(rest, 1, RLENGTH)
    rest = substr(rest, RLENGTH + 1)
    return rest ~ /^([ \t]|$)/ ? 1 : -1
  }
  # An unclosed quote last on the line opens an argument that later lines
  # continue, as sh -c bodies do.
  if (rest ~ /^\047[^\047]*$/) { tok = rest; rest = ""; return 1 }
  return -1
}
function problem(s,   low, n, cap, launch, ntok, i, mem, cpu, r) {
  if (FILENAME ~ /\.ya?ml$/ && s ~ /(^[ \t]*(-[ \t]+)?|[{,][ \t]*)["\047]?(container|services)["\047]?[ \t]*:/)
    return keymsg
  # container-limits: exempt names of files and directories, none of which is run as a command
  gsub(/riftal-docker-label|ci-docker-label\.sh|dockerfiles|Dockerfile/, "", s)
  low = tolower(s)
  # container-limits: exempt counts the word this check is triggered by
  n = gsub(/docker/, "", low)
  if (n == 0) return ""
  if (s ~ /^[ \t]*#/) {
    # container-limits: exempt names the only backquoted spans a comment may hold
    gsub(/`docker( run( --help)?| create| rm| compose( config)?)?`/, "", s)
    # Inside a string opened on an earlier line, a quote here would close it
    # and run what follows, and a substitution runs where it stands.
    return s ~ /[`"\047]|\$\(/ ? unread : ""
  }
  if (n != 1) return unread
  sub(/[ \t]+(\|\| (true|continue|exit 1)|\\)[ \t]*$/, "", s)
  # container-limits: exempt the capture form name="$(...)" around an allowlisted command
  if (match(s, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*="\$\(docker[ \t]/)) {
    if (s !~ /\)"$/) return unread
    s = substr(s, RLENGTH - 6, length(s) - RLENGTH + 5)
    cap = 1
  }
  sub(/^[ \t]+/, "", s)
  # container-limits: exempt the one launch form this check reads
  if (!cap && match(s, /^docker[ \t]+(run|create)[ \t]/)) launch = 1
  # container-limits: exempt the allowlist of commands that start no container
  else if (!match(s, /^docker[ \t]+(ps|inspect|stop|rm|(network|volume)[ \t]+(ls|rm|create|inspect))([ \t]|$)/)) return unread
  rest = substr(s, RLENGTH + 1)
  split("", toks)
  while ((r = take()) > 0) toks[++ntok] = tok
  if (r < 0) return unread
  if (!launch) return ""
  for (i = 1; i <= ntok; i++) {
    tok = toks[i]
    if (tok == "-m" || tok == "--memory") { if (i < ntok) mem = 1; i++ }
    else if (tok == "--cpus") { if (i < ntok) cpu = 1; i++ }
    else if (tok ~ /^(-m|--memory=)./) mem = 1
    else if (tok ~ /^--cpus=./) cpu = 1
    else if (index(" " vals " ", " " tok " ")) i++
    else if (tok !~ /^-/) break
  }
  if (mem && cpu) return ""
  return nolimit (mem ? "--cpus" : cpu ? "-m/--memory" : "-m/--memory and --cpus")
}
BEGIN {
  # Options of run and create that take a separate value.
  # An option missing here is read as a flag, which can only end the options
  # early and report a launch, never pass one.
  vals = "-v --volume -e --env --name --network --label -l -w --workdir --entrypoint -p --publish --mount -u --user --env-file --platform"
  nolimit = "a container launch without "
  unread = "neither a plain limited run or create nor an allowlisted command"
  keymsg = "a workflow job container or service, which takes no -m or --cpus"
  reason = "a container-limits line that is not exempt <reason>"
  unused = "a container-limits exemption with nothing under it to exempt"
}
FNR == 1 && pend { report(pfile, pend, unused); pend = 0 }
{
  prev = pend; pend = 0
  if ($0 ~ /^[ \t]*#[ \t]*container-limits/) {
    if ($0 ~ /^[ \t]*# container-limits: exempt [^ \t]/) { pend = FNR; pfile = FILENAME }
    else report(FILENAME, FNR, reason)
  }
  m = problem($0)
  if (m != "" && prev) prev = 0
  else if (m != "") report(FILENAME, FNR, m)
  if (prev) report(FILENAME, prev, unused)
}
END {
  if (pend) report(pfile, pend, unused)
  exit bad
}
' "${list[@]}"
