#!/usr/bin/env bash
# Fails on any `docker run` or `docker create` in the CI workflows and scripts
# without both a memory limit, -m or --memory, and --cpus. The CI runners share
# one docker engine with every lane on the development PC, so one container
# with no limit can starve all of them. A docker command whose verb is a
# variable may be a launch this check cannot read, so it is reported too.
#
# Either is admitted only under a whole comment line directly above it:
#
#   # container-limits: exempt <why this needs no limit>
#
# which excuses the first report on the line below and nothing else. An
# exemption that excuses nothing is itself reported.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  set -- .github/workflows .github/scripts
fi
found="$(find "$@" -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \) -print)"
mapfile -t files < <(printf '%s' "$found")
printf 'found %d script(s) and workflow(s)\n' "${#files[@]}"
# A path that holds nothing to check is a wrong path, never a clean tree.
if [ "${#files[@]}" -eq 0 ]; then
  printf 'nothing to check under %s\n' "$*" >&2
  exit 1
fi

# Backslash continuations are joined first, so a flag lines below its launch
# still counts. `$DOCKER`, `${DOCKER}` and their quoted forms read as `docker`.
awk '
  # The options of docker run and docker create that take a value, from
  # `docker run --help` on docker 29.1.3. A short option takes one when its
  # letter is in short_value.
  BEGIN {
    split("add-host annotation attach blkio-weight blkio-weight-device cap-add cap-drop " \
      "cgroup-parent cgroupns cidfile cpu-period cpu-quota cpu-rt-period cpu-rt-runtime " \
      "cpu-shares cpus cpuset-cpus cpuset-mems detach-keys device device-cgroup-rule " \
      "device-read-bps device-read-iops device-write-bps device-write-iops dns dns-option " \
      "dns-search domainname entrypoint env env-file expose gpus group-add health-cmd " \
      "health-interval health-retries health-start-interval health-start-period " \
      "health-timeout hostname ip ip6 ipc isolation label label-file link link-local-ip " \
      "log-driver log-opt mac-address memory memory-reservation memory-swap " \
      "memory-swappiness mount name network network-alias oom-score-adj pid pids-limit " \
      "platform publish pull restart runtime security-opt shm-size stop-signal " \
      "stop-timeout storage-opt sysctl tmpfs ulimit user userns uts volume volume-driver " \
      "volumes-from workdir", names, " ")
    for (i in names) takes_value[names[i]] = 1
    short_value = "acehlmpuvw"
  }
  # Splits s into words at blanks outside quotes, reading backslash escapes and
  # the quotes '...', "..." and $'...', so a limit inside a quoted value such
  # as -e "X -m 1g" is not a flag.
  function shell_words(s, w,    n, i, ch, q, cur) {
    n = 0
    q = ""
    cur = ""
    for (i = 1; i <= length(s); i++) {
      ch = substr(s, i, 1)
      if (q == "\047") {
        if (ch == q) q = ""
      } else if (q == "$") {
        if (ch == "\\") ch = substr(s, i++, 2)
        else if (ch == "\047") q = ""
      } else if (ch == "\\") {
        ch = substr(s, i++, 2)
      } else if (q == "\"") {
        if (ch == q) q = ""
      } else if (ch == "$" && substr(s, i + 1, 1) == "\047") {
        ch = substr(s, i++, 2)
        q = "$"
      } else if (ch == "\"" || ch == "\047") {
        q = ch
      } else if (ch == " " || ch == "\t") {
        if (cur != "") w[++n] = cur
        cur = ""
        continue
      }
      cur = cur ch
    }
    if (cur != "") w[++n] = cur
    return n
  }
  # docker reads options only up to the image and hands every later word, a
  # separator or a comment included, to the container. An option missing from
  # takes_value is read as taking no value, so its value ends the search as if
  # it were the image: it can make a launch be reported, never let one through.
  function read_limits(seg,    w, n, i, t, c, name) {
    mem = cpu = 0
    n = shell_words(seg, w)
    for (i = 1; i <= n; i++) {
      t = w[i]
      if (t !~ /^-./) return
      if (t ~ /^--/) {
        name = substr(t, 3)
        if (index(name, "=")) name = substr(name, 1, index(name, "=") - 1)
        else if (name in takes_value) i++
        if (name == "memory") mem = 1
        if (name == "cpus") cpu = 1
        continue
      }
      # In a cluster such as -dm 1g, the first letter that takes a value takes
      # the rest of the word, or the next word when none is left.
      for (c = 2; c <= length(t); c++) {
        if (index(short_value, substr(t, c, 1))) {
          if (substr(t, c, 1) == "m") mem = 1
          if (c == length(t)) i++
          break
        }
      }
    }
  }
  function report(file, at, what) {
    if (exempt_at) exempt_at = 0
    else { printf "%s:%d: %s\n", file, at, what; bad = 1 }
  }
  function drop_exempt() {
    if (exempt_at) {
      printf "%s:%d: a container-limits exemption with nothing under it to exempt\n", exempt_file, exempt_at
      bad = 1
    }
    exempt_at = 0
  }
  function flush() {
    if (cmd != "") check(cmd, at, at_file)
    cmd = ""
  }
  function check(cmd, at, file,    rest, head, what) {
    rest = cmd
    while (match(rest, /docker[ \t]+(container[ \t]+)?("?[$]|(run|create)([ \t]|$))/)) {
      head = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH - 1)
      if (head ~ /[$]$/) {
        report(file, at, "a docker command whose verb cannot be read")
        continue
      }
      launches++
      read_limits(rest)
      what = "a container " (head ~ /create/ ? "created" : "started") " without "
      if (!mem || !cpu) report(file, at, what (mem ? "--cpus" : cpu ? "-m/--memory" : "-m/--memory and --cpus"))
    }
    drop_exempt()
  }
  FNR == 1 { flush(); drop_exempt() }
  {
    line = $0
    if (cmd == "" && line ~ /^[ \t]*#/) {
      drop_exempt()
      if (sub(/^[ \t]*# container-limits:/, "", line)) {
        if (line ~ /^ exempt[ \t]+[^ \t]/) {
          exempt_at = FNR
          exempt_file = FILENAME
        } else {
          printf "%s:%d: a container-limits line that is not exempt <reason>\n", FILENAME, FNR
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
  END { flush(); drop_exempt(); printf "checked %d launch(es)\n", launches; exit bad }
' "${files[@]}"
