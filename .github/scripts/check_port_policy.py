#!/usr/bin/env python3
"""Enforce this repo's port rules on one compose file or one shell script.

Reads the compose model `docker compose config --format json` prints for the
file on stdin, so interpolation, anchors, short and long port syntax and port
ranges arrive already resolved by compose itself. A `${VAR:-127.0.0.1}` bind is
judged by its default, the address the stack takes when nobody widens it.

BEDROCK_TCP_PUBLISH. Bedrock is RakNet over UDP. A publish of 19132 that is not
udp gives a container that looks healthy and that no client can join. Compose
reads a publish with no protocol as tcp, so the mistake is silent.

LOOPBACK_BIND_REQUIRED. Instances run with xbox-auth off, so a publish on any
address wider than 127.0.0.1 lets whoever reaches it claim any identity. A
publish with no address binds every interface.

HOST_NETWORK_MODE. network_mode: host puts every listening port on every
interface and leaves no ports list for the rule above to read.

With --shell, every docker, podman or nerdctl command in a script, and every
expansion used as a command word before run, create, container or compose, is
read to its end, and the publishes and network of a run, create or compose run
are held to the rules above.

RUN_UNPARSEABLE. A script command this cannot fully account for. It is
reported, never read as clean, because what it hides is what the rules seek.

Usage: docker compose -f FILE config --format json | check_port_policy.py FILE
       check_port_policy.py --shell FILE
Exit 0 when clean, 1 when there are findings, 2 when the input is unreadable.
"""

from __future__ import annotations

import json
import re
import sys

BEDROCK_PORTS = {19132}
LOOPBACK_BIND = "127.0.0.1"


class Finding:
    def __init__(self, code, path, where, detail):
        self.code = code
        self.path = path
        self.where = where
        self.detail = detail

    def __str__(self):
        return f"{self.path}: {self.code}: {self.where}: {self.detail}"


def check_publish(findings, path, where, port):
    target = port.get("target")
    proto = str(port.get("protocol") or "tcp").lower()
    host_ip = port.get("host_ip") or ""

    if target in BEDROCK_PORTS and proto != "udp":
        findings.append(
            Finding(
                "BEDROCK_TCP_PUBLISH",
                path,
                where,
                f"port {target} published as {proto}. Bedrock is RakNet over UDP; "
                f"declare it as {target}/udp or no client can join.",
            )
        )

    if host_ip != LOOPBACK_BIND:
        findings.append(
            Finding(
                "LOOPBACK_BIND_REQUIRED",
                path,
                where,
                f"publishes {target}/{proto} on {host_ip or 'every interface'}. "
                f"A publish binds {LOOPBACK_BIND} and nothing wider.",
            )
        )


def check_compose(path, model, findings):
    services = model.get("services") or {}
    for name, service in services.items():
        where = f"services.{name}"

        if service.get("network_mode") == "host":
            findings.append(
                Finding(
                    "HOST_NETWORK_MODE",
                    path,
                    where,
                    "network_mode: host puts every listening port on every "
                    "interface and bypasses the publish rules entirely.",
                )
            )

        for index, port in enumerate(service.get("ports") or []):
            check_publish(findings, path, f"{where}.ports[{index}]", port)


class Unparseable(Exception):
    pass


def table(values, bools, shorts):
    return set(values.split()), set(bools.split()), dict(s.split("=") for s in shorts.split())


# docker 29.1.3's own help for docker, run, compose and compose run, the hidden --net and
# --net-alias, and the nerdctl and podman globals that pick a namespace or an engine. A flag
# missing here makes its command RUN_UNPARSEABLE: a gap costs a report, never a clean read.
GLOBAL = table(
    "config context host log-level tlscacert tlscert tlskey namespace address snapshotter "
    "cni-path cni-netconfpath data-root connection url root runroot",
    "debug tls tlsverify version remote",
    "c=context H=host l=log-level n=namespace a=address D=debug v=version r=remote",
)
RUN = table(
    "add-host annotation attach blkio-weight blkio-weight-device cap-add cap-drop cgroup-parent "
    "cgroupns cidfile cpu-period cpu-quota cpu-rt-period cpu-rt-runtime cpu-shares cpus "
    "cpuset-cpus cpuset-mems detach-keys device device-cgroup-rule device-read-bps "
    "device-read-iops device-write-bps device-write-iops dns dns-option dns-search domainname "
    "entrypoint env env-file expose gpus group-add health-cmd health-interval health-retries "
    "health-start-interval health-start-period health-timeout hostname ip ip6 ipc isolation "
    "label label-file link link-local-ip log-driver log-opt mac-address memory "
    "memory-reservation memory-swap memory-swappiness mount name net net-alias network "
    "network-alias oom-score-adj pid pids-limit platform publish pull restart runtime "
    "security-opt shm-size stop-signal stop-timeout storage-opt sysctl tmpfs ulimit user "
    "userns uts volume volume-driver volumes-from workdir",
    "detach help init interactive no-healthcheck oom-kill-disable privileged publish-all quiet "
    "read-only rm sig-proxy tty use-api-socket",
    "a=attach c=cpu-shares e=env h=hostname l=label m=memory p=publish u=user v=volume "
    "w=workdir d=detach i=interactive t=tty P=publish-all q=quiet",
)
COMPOSE = table(
    "ansi env-file file parallel profile progress project-directory project-name",
    "all-resources compatibility dry-run",
    "f=file p=project-name",
)
COMPOSE_RUN = table(
    "cap-add cap-drop entrypoint env env-from-file label name publish pull user volume workdir",
    "build detach dry-run interactive no-TTY no-deps quiet quiet-build quiet-pull "
    "remove-orphans rm service-ports use-aliases",
    "e=env l=label p=publish u=user v=volume w=workdir d=detach i=interactive T=no-TTY q=quiet "
    "P=service-ports",
)
# A start of a word: after a blank, a command separator or a quote, so a command inside
# bash -c "..." or an ssh argument is read as the command it is.
WORD_START = re.compile(r"(?<![^\s;&|(`'\"])(?=[^\s;&|()])")
CONTAINER = re.compile(r"(?:.*/)?(?:docker|podman|nerdctl)(?:-compose)?")
VERBS = {(verb, "lit") for verb in ("run", "create", "container", "compose")}
PROBE = re.compile(r"(?:\b(?:which|type|hash|whereis)|-[vV])\s+$")
# A docker publish, [ip:][host:]container[/proto], each port a number or a range.
PUBLISH = re.compile(
    r"(?:(\[[0-9a-fA-F:.]*\]|[^:\[\]]*):(?=\d*(?:-\d+)?:))?(?:(\d*(?:-\d+)?):)?(\d+)(?:-(\d+))?"
    r"(?:/(\w+))?"
)
REDIRECT = re.compile(r"[0-9]*(?:&>>?|<<<|<<-?|>>|>\||<>|[<>]&?)")
NAME = re.compile(r"[A-Za-z_]\w*|[0-9@*#?$!-]")
BLANK = re.compile(r"(?:[ \t]|\\\n)*")


def closing(text, i, quote, escapes=True):
    while i < len(text) and text[i] != quote:
        i += 2 if escapes and text[i] == "\\" else 1
    if i >= len(text):
        raise Unparseable(f"a {quote} that never closes")
    return i + 1


def balanced(text, i):
    """The end of the $( or ${ group whose bracket is at i."""
    opener, close, depth = text[i], {"(": ")", "{": "}"}[text[i]], 0
    while i < len(text):
        if text[i] in "'\"`\\":
            i = segment(text, i, "lit")[0]
            continue
        depth += (text[i] == opener) - (text[i] == close)
        i += 1
        if depth == 0:
            return i
    raise Unparseable(f"a ${opener} that never closes")


def expansion(text, i):
    """The end of the expansion whose $ or backtick is at i, or i + 1 for a plain $."""
    if text[i] == "`":
        return closing(text, i + 1, "`")
    if text[i + 1:i + 2] in ("(", "{"):
        return balanced(text, i + 1)
    name = NAME.match(text, i + 1)
    return name.end() if name else i + 1


def dquote(text, i):
    """The end of the string whose " is at i, whether it expands, and whether into many words."""
    i, dynamic, many = i + 1, False, False
    while i < len(text) and text[i] != '"':
        end = i + 2 if text[i] == "\\" else expansion(text, i) if text[i] in "$`" else i + 1
        if end > i + 1 and text[i] in "$`":
            dynamic, many = True, many or "@" in text[i:end]
        i = end
    if i >= len(text):
        raise Unparseable('a " that never closes')
    return i + 1, dynamic, many


def segment(text, i, kind):
    """One piece of a word: its end, its text, whether it expands, and the word's kind."""
    c = text[i]
    if c == "\\":
        return i + 2, text[i + 1:i + 2].strip("\n"), False, kind
    if c == "'":
        end = closing(text, i + 1, "'", False)
        return end, text[i + 1:end - 1], False, kind
    if text.startswith("$'", i):
        return closing(text, i + 2, "'"), "$'", True, kind
    if c == '"':
        end, dynamic, many = dquote(text, i)
        piece = re.sub(r'\\\n|\\([$`"\\])', r"\1", text[i + 1:end - 1])
        return end, piece, dynamic, "many" if many else kind
    end = expansion(text, i) if c in "$`" else i + 1
    if end > i + 1:
        return end, text[i:end], True, "many"
    return end, c, False, "many" if c in "*?[{" else kind


def word(text, i):
    """One word from i: its end and (text, kind, lead). kind is lit for exactly this text,
    one for one word of unknown text, many for any number of words. lead is its first
    character when that is literal. A quote that never closes may close the string the
    command sits in, as in bash -c "docker run ... image", so the word ends before it."""
    value, kind, lead = "", "lit", None
    while i < len(text) and text[i] not in " \t\n;&|()<>":
        try:
            end, piece, dynamic, kind = segment(text, i, kind)
        except Unparseable:
            if not value:
                raise
            return i, (value, "one", lead or "")
        kind = "one" if dynamic and kind == "lit" else kind
        if lead is None and (piece or dynamic):
            lead = piece[:1].strip("$`")
        value, i = value + piece, end
    return i, (value, kind, lead or "")


def command_words(text, i):
    """The words of the command at i, ending in a bad word where the lexer cannot read on."""
    words = []
    try:
        while True:
            i = BLANK.match(text, i).end()
            redirect = REDIRECT.match(text, i)
            if redirect:
                end = word(text, BLANK.match(text, redirect.end()).end())[0]
            elif i >= len(text) or text[i] in "\n;&|)":
                return words
            else:
                end, found = word(text, i)
                if end == i:
                    raise Unparseable(f"{text[i]} where a word belongs")
                words.append(found)
            i = end
    except Unparseable as exc:
        words.append((str(exc), "bad", ""))
        return words


def sized(word_):
    if word_[1] == "bad":
        raise Unparseable(word_[0])
    if word_[1] == "many":
        raise Unparseable(f"{word_[0]!r} may expand to any number of words, any of them a flag")
    return word_


def literal(word_):
    if sized(word_)[1] != "lit":
        raise Unparseable(f"{word_[0]!r} may expand to any subcommand")
    return word_[0]


def options(words, i, flags, seen):
    """Add each flag from words[i] to seen as (name, value word). Returns the index of the
    first operand, which for run is the image: every word after it is the container's."""
    values, bools, shorts = flags
    while i < len(words):
        text, kind, lead = sized(words[i])
        if kind == "one" and lead in ("", "-"):
            raise Unparseable(f"{text!r} may expand to a flag")
        if text == "--":
            return i + 1
        if kind == "one" or text[:1] != "-" or text == "-":
            return i
        pairs = []
        if text[1] == "-":
            name, eq, value = text[2:].partition("=")
            if name not in values | bools:
                raise Unparseable(f"--{name} is a flag this checker cannot size")
            pairs.append((name, value if eq else None))
        for k, letter in enumerate(text[1:] if text[1] != "-" else "", 2):
            if letter not in shorts:
                raise Unparseable(f"-{letter} in {text} is a flag this checker cannot size")
            pairs.append((shorts[letter], text[k:].removeprefix("=") or None))
            if shorts[letter] in values:
                break
            pairs[-1] = (shorts[letter], None)
        for name, value in pairs:
            if name in values and value is None:
                i += 1
                if i == len(words):
                    return i
                seen.append((name, sized(words[i])))
            else:
                seen.append((name, (value or "true", "lit", "")))
        i += 1
    return i


def check_command(words, findings, path, where):
    seen, i, verb = [], 0, "compose"
    if not words[0][0].endswith("-compose"):
        i = options(words, 1, GLOBAL, [])
        if i == len(words):
            raise Unparseable("a container binary with no subcommand, so what it runs is not here")
        verb = literal(words[i])
        if verb == "container" and i + 1 < len(words):
            i += 1
            verb = literal(words[i])
        if verb in ("service", "stack", "pod", "kube", "play"):
            raise Unparseable(f"{verb} publishes outside run, which this policy does not read")
        if verb in ("run", "create"):
            options(words, i + 1, RUN, seen)
    if verb == "compose":
        i = options(words, i + 1, COMPOSE, [])
        if i < len(words) and literal(words[i]) == "run":
            options(words, i + 1, COMPOSE_RUN, seen)
    for name, (text, kind, _) in seen:
        if name == "publish" and kind != "lit":
            raise Unparseable(f"the publish {text!r} is known only when the script runs")
        if name in ("network", "net") and kind != "lit":
            raise Unparseable(f"the network {text!r} is known only when the script runs")
        spec = PUBLISH.fullmatch(text) if name == "publish" else True
        if not spec:
            raise Unparseable(f"{text!r} is not a publish this checker can read")
        if spec is not True:
            low, high = int(spec[3]), int(spec[4] or spec[3])
            target = next((p for p in sorted(BEDROCK_PORTS) if low <= p <= high), low)
            port = {"target": target, "protocol": spec[5], "host_ip": spec[1]}
            check_publish(findings, path, where, port)
        if name in ("network", "net") and text == "host":
            findings.append(Finding("HOST_NETWORK_MODE", path, where, "--network host puts every "
                                    "listening port on every interface and bypasses the publish rules."))
        if name == "publish-all" and text != "false":
            findings.append(Finding("LOOPBACK_BIND_REQUIRED", path, where,
                                    "--publish-all publishes every exposed port on every interface."))


def inside_string(head):
    """Whether the end of head, the text before a word on its line, is inside a quoted string."""
    state, i = "", 0
    while i < len(head):
        c = head[i]
        i += 2 if c == "\\" and state != "'" else 1
        if state:
            state = "" if c == state else state
        elif c in "'\"":
            state = c
    return bool(state)


def check_script(path, text, findings):
    for match in WORD_START.finditer(text):
        start = match.start()
        head = text[text.rfind(chr(10), 0, start) + 1:start]
        if head.lstrip().startswith("#"):
            continue
        where = f"line {text.count(chr(10), 0, start) + 1}"
        try:
            value, kind, lead = word(text, start)[1]
        except Unparseable:
            continue
        words = command_words(text, start)
        try:
            if head.rstrip().endswith("alias") and re.search(r"docker|podman|nerdctl", value):
                raise Unparseable("an alias that names a container binary")
            if kind == "lit":
                if not CONTAINER.fullmatch(value):
                    continue
                if text.rfind("=(", 0, start) > text.rfind(")", 0, start):
                    raise Unparseable("a container command held in an array runs where this cannot see it")
                if len(words) == 1 and PROBE.search(head):
                    continue
            elif lead or inside_string(head):
                continue
            else:
                try:
                    after = options(words, 1, GLOBAL, [])
                except Unparseable:
                    after = next((k for k, w in enumerate(words) if (w[0], w[1]) in VERBS), len(words))
                if after >= len(words) or (words[after][0], words[after][1]) not in VERBS:
                    continue
            check_command(words, findings, path, where)
        except Unparseable as exc:
            findings.append(Finding("RUN_UNPARSEABLE", path, where, f"{exc}. Write the command "
                                    "so every word this policy decides on is visible here."))


def main(argv):
    shell = argv[1:2] == ["--shell"]
    if len(argv) != 2 + shell:
        sys.stderr.write(__doc__)
        return 2
    path = argv[-1]
    try:
        model = {} if shell else json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"{path}: no compose model on stdin: {exc}\n")
        return 2
    if not isinstance(model, dict):
        sys.stderr.write(f"{path}: the compose model is not a mapping\n")
        return 2

    findings = []
    check_compose(path, model, findings)
    if shell:
        with open(path, encoding="utf-8", errors="replace") as handle:
            check_script(path, handle.read(), findings)
    for finding in findings:
        print(f"::error file={finding.path}::{finding}")
    print(f"{len(findings)} finding(s) in {path}")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
