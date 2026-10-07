#!/usr/bin/env bash
# Fails on any container started in the CI workflows and scripts without both
# a memory limit, -m or --memory, and --cpus: the CI runners share one docker
# engine with every lane on the development PC, so one unlimited container can
# starve all of them. It fails closed. A docker command it cannot read as a
# launch it checks, or as a command that starts no container, is reported, as
# are compose launches and a workflow container:, services: or docker:// image.
#
# A report is admitted only under a whole comment line directly above it,
# `# container-limits: exempt <why this needs no limit>`, which excuses the
# first report on the line below. An exemption that excuses nothing is reported.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  set -- .github/workflows .github/scripts
fi
# Every file is read, so a script named without .sh is never skipped.
found="$(find "$@" -type f -print)"
mapfile -t files < <(printf '%s' "$found")
printf 'found %d script(s) and workflow(s)\n' "${#files[@]}"
# A path that holds nothing to check is a wrong path, never a clean tree.
if [ "${#files[@]}" -eq 0 ]; then
  printf 'nothing to check under %s\n' "$*" >&2
  exit 1
fi

# Backslash continuations are joined first, so a flag lines below its launch
# still counts.
awk '
  # The options of docker run and docker create that take a value, and the
  # commands that start no container, from `docker run --help` and `docker --help`
  # on docker 29.1.3. A short option takes one when its letter is in short_value.
  BEGIN {
    split("add-host annotation attach blkio-weight blkio-weight-device cap-add cap-drop cgroup-parent cgroupns " \
      "cidfile cpu-period cpu-quota cpu-rt-period cpu-rt-runtime cpu-shares cpus cpuset-cpus cpuset-mems " \
      "detach-keys device device-cgroup-rule device-read-bps device-read-iops device-write-bps device-write-iops " \
      "dns dns-option dns-search domainname entrypoint env env-file expose gpus group-add health-cmd " \
      "health-interval health-retries health-start-interval health-start-period health-timeout hostname ip ip6 " \
      "ipc isolation label label-file link link-local-ip log-driver log-opt mac-address memory memory-reservation " \
      "memory-swap memory-swappiness mount name network network-alias oom-score-adj pid pids-limit platform " \
      "publish pull restart runtime security-opt shm-size stop-signal stop-timeout storage-opt sysctl tmpfs " \
      "ulimit user userns uts volume volume-driver volumes-from workdir", names, " ")
    for (i in names) takes_value[names[i]] = 1
    short_value = "acehlmpuvw"
    split("attach build builder commit config context cp diff events exec export history image images import " \
      "info inspect kill load login logout logs manifest network node pause port ps pull push rename restart " \
      "rm rmi save search secret start stats stop system tag top trust unpause update version volume wait", names, " ")
    for (i in names) inert[names[i]] = 1
    unreadable = "a docker command or container this check cannot read"
  }
  function emit(w) {
    if (cur != "") w[++n] = cur
    cur = ""
  }
  # Splits s into words at blanks outside quotes, reading backslash escapes and
  # the quotes '...', "..." and $'...', so a limit inside a quoted value such
  # as -e "X -m 1g" is not a flag. $(...) and `...` open a new level of
  # quoting, and their bounds end a word, so a command inside one is read.
  function shell_words(s, w,    i, ch, q, d, sq, sk) {
    n = d = 0
    q = cur = ""
    for (i = 1; i <= length(s); i++) {
      ch = substr(s, i, 1)
      if (q == "\047" || q == "$") {
        if (ch == "\\" && q == "$") ch = substr(s, i++, 2)
        else if (ch == "\047") q = ""
      } else if (ch == "\\") {
        ch = substr(s, i++, 2)
      } else if (d && q == "" && ch == sk[d]) {
        emit(w)
        q = sq[d--]
      } else if (ch == "`" || substr(s, i, 2) == "$(") {
        if (ch == "$") ch = substr(s, i++, 2)
        sq[++d] = q
        sk[d] = ch == "`" ? "`" : ")"
        q = ""
        cur = cur ch
        emit(w)
        continue
      } else if (q == "\"") {
        if (ch == q) q = ""
      } else if (ch == "$" && substr(s, i + 1, 1) == "\047") {
        ch = substr(s, i++, 2)
        q = "$"
      } else if (ch == "\"" || ch == "\047") {
        q = ch
      } else if (ch == " " || ch == "\t") {
        emit(w)
        continue
      }
      cur = cur ch
    }
    emit(w)
    return n
  }
  # docker reads options only up to the image and hands every later word to
  # the container. An option missing from takes_value is read as taking no
  # value, so its value ends the search as if it were the image: it can make a
  # launch be reported, never let one through.
  function read_limits(w, n, i,    t, c, name) {
    mem = cpu = 0
    for (; i <= n && (t = w[i]) ~ /^-./; i++) {
      if (t ~ /^--/) {
        name = substr(t, 3)
        if (index(name, "=")) name = substr(name, 1, index(name, "=") - 1)
        else if (name in takes_value) i++
        mem = mem || name == "memory"
        cpu = cpu || name == "cpus"
        continue
      }
      # In a cluster such as -dm 1g, the first letter that takes a value takes
      # the rest of the word, or the next word when none is left.
      for (c = 2; c <= length(t) && !index(short_value, substr(t, c, 1)); c++);
      mem = mem || substr(t, c, 1) == "m"
      if (c == length(t)) i++
    }
  }
  # The index of the first word after docker that is neither a redirection
  # nor one of the global options of `docker --help`.
  function verb_at(w, n, i,    t) {
    for (i++; i <= n; i++) {
      if ((t = w[i]) ~ /^[0-9&]*[<>]/) i += (t ~ /[<>&]$/)
      else if (t ~ /^(-[cHl]|--(config|context|host|log-level|tlscacert|tlscert|tlskey))$/) i++
      else if (t !~ /^(-[Dvh]|--(debug|tls|tlsverify|version|help)|--(config|context|host|log-level|tlscacert|tlscert|tlskey)=.*)$/) return i
    }
    return i
  }
  function bare(t) {
    gsub(/[\\"\047]/, "", t)
    return t
  }
  function say(file, at, what) {
    printf "%s:%d: %s\n", file, at, what
    bad = 1
  }
  function report(file, at, what) {
    if (!exempt_at) say(file, at, what)
    exempt_at = 0
  }
  function drop_exempt() {
    if (exempt_at) say(exempt_file, exempt_at, "a container-limits exemption with nothing under it to exempt")
    exempt_at = 0
  }
  function check(cmd, at, file, quoted,    w, n, i, j, d, v, vd, named) {
    n = shell_words(cmd, w)
    for (i = 1; i <= n; i++) {
      d = bare(w[i])
      # A quoted string may hold a command, as in sh -c '...', or a message
      # naming docker, so only a launch read inside one counts.
      if (w[i] ~ /["\047]/ && d ~ /[ \t]/) check(d, at, file, 1)
      # Docker is a word ending in docker, a variable named for it, or any
      # variable followed by run, create or container past global options.
      named = d ~ /(^|[\/(])docker(-compose)?$/ || toupper(w[i]) ~ /^"?[$][{]?[A-Z0-9_]*DOCKER/
      if (!named && w[i] !~ /^"?[$]/) continue
      v = d ~ /compose$/ ? i : verb_at(w, n, i)
      vd = d ~ /compose$/ ? "compose" : bare(w[v])
      if (vd == "container" && (vd = bare(w[++v])) ~ /^[a-z]+$/ && vd !~ /^(run|create)$/) continue
      if (v > n || w[v] ~ /^(\]|[);|&}])/) continue
      if (vd ~ /^(run|create)$/ && w[v] !~ /[$`]/) {
        launches++
        read_limits(w, n, v + 1)
        if (!mem || !cpu) report(file, at, "a container " (vd == "run" ? "started" : "created") " without " \
          (mem ? "--cpus" : cpu ? "-m/--memory" : "-m/--memory and --cpus"))
      } else if (named && !quoted && vd == "compose") {
        for (j = v + 1; j <= n && w[j] !~ /(^[&|)]|;$)/; j++)
          if (w[j] ~ /^(run|create|up)$/) { report(file, at, unreadable); break }
      } else if (named && !quoted && (w[v] ~ /[$`]/ || !(vd in inert)))
        report(file, at, unreadable)
    }
  }
  function flush() {
    if (cmd != "") check(cmd, at, at_file, 0)
    cmd = ""
    drop_exempt()
  }
  FNR == 1 { flush() }
  {
    line = $0
    if (cmd == "" && line ~ /^[ \t]*#/) {
      drop_exempt()
      if (!sub(/^[ \t]*# container-limits:/, "", line)) next
      if (line !~ /^ exempt[ \t]+[^ \t]/) say(FILENAME, FNR, "a container-limits line that is not exempt <reason>")
      else exempt_at = FNR
      exempt_file = FILENAME
      next
    }
    if (cmd == "") { at = FNR; at_file = FILENAME }
    if (line ~ /^[ \t-]*(container|services):|uses:[ \t]*["\047]?docker:/) report(FILENAME, FNR, unreadable)
    cmd = cmd line
    if (sub(/\\$/, " ", cmd)) next
    flush()
  }
  END { flush(); printf "checked %d launch(es)\n", launches; exit bad }
' "${files[@]}"
