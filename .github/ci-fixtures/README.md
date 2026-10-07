# CI fixtures

Not part of the stack. Nothing here is ever built, run or deployed. These files
exist so `.github/scripts/selftest.sh` can feed each CI check input it must
reject and input it must accept.

These fixtures are what makes hadolint and `docker compose config` provably
able to fail on this commit rather than on some future one. `selftest.sh`
drives them through `.github/scripts/scan.sh` itself, the same discovery,
dispatch and loop the real scans in `.github/workflows/ci.yml` run, not a
second copy of the two calls.

Every file's first comment states the outcome it must produce. Change a check,
and change the fixture that covers it in the same commit, or the self-test goes
red. That is the intended behaviour.

`good/` is not decoration. A check that rejects a correct file is as broken as
one that accepts a wrong file, because the first person it blocks weakens it.

Each bad fixture carries exactly one defect and is asserted at the line or lines
that defect is reported on.
A fixture that trips several rules at once stays red when the rule it was
written for is switched off, so it keeps looking like coverage while pinning
nothing.

`good/Containerfile` and `bad/Containerfile` are `good/Dockerfile` and
`bad/Dockerfile` again under the OCI-neutral name, so a discovery regression
that stops matching `Containerfile` goes red here instead of shipping silently.

`good/stack.yaml` and `good/rollout.yml` are a pair, and they point in opposite
directions. One is compose under a name no convention would match, the other is
YAML with a `services` key that is nested rather than top level. Filename-based
discovery misses the first; matching `services` anywhere in the file claims the
second. Only a top-level key check gets both right.

`good/php-plugins/` and the three `bad/php-plugins-*/` directories are batches, not
single files, because the defect they cover only shows up across a multi-file
`images/plugins/*.php` glob: a broken file's own exit status has to survive being one
of several `php -l` invocations in a loop, not just one on its own. Each `bad/`
directory carries exactly one broken file, named `a_broken.php`, `m_broken.php` or
`z_broken.php` for its position in alphabetical glob order, alongside two untouched
valid companions, so the self-test can assert both that the broken file is named as a
failure and that the companion on the far side of it still gets its own clean result.
Three implementation rounds on this check each held for one position and broke on
another; that is why all three positions are pinned.

`good/cleanup.sh` and every `bad/cleanup-*.sh` drive
`.github/scripts/container-cleanup.sh`, which refuses a `docker run` or
`docker create` without `--rm` and a `docker rm` without `-v`, because either
leaves `mysql:8`'s anonymous volume on the shared engine. `bad/cleanup-run.sh`
puts a second run with `--rm` on the same line, so a check that reads past the
end of a command goes red.

The scanner matches through alternatives: two forms of create, four variable
spellings of docker, five shell separators, the next `docker`, and a verb that
ends its line. Each has its own bad fixture, because a fixture that one
alternative alone rejects is the only thing that goes red when that alternative
is deleted. `bad/cleanup-quoted-comment.sh` and `bad/cleanup-argcount.sh` put a
`#` that starts no comment before a run, so a scanner that drops everything
after any `#` goes red. `bad/cleanup-continued-hash.sh` puts a run on a line
that starts with `#` yet is no comment, because a continuation joins it to the
word above.

A flag after a trailing `#` lends a command nothing, but the scanner never
deletes the text after a `#`: it only stops looking for that command's flags
there, so a `#` it misreads can report a command and never hide one.
`bad/cleanup-comment*.sh` and `bad/cleanup-continued-comment.sh` put the flag
in a comment. Every `bad/cleanup-hash-*.sh` puts a `#` that a shell reads as
text, inside quotes, a here-document, a parameter expansion or a word, ahead of
or beside a leaking run, so a scanner that strips comments wrongly goes red.

Every `bad/cleanup-optout-*.sh` fixture holds one way a
`# container-cleanup: keep <reason>` line fails to excuse the container under
it. Four are lines that are not `keep <reason>`, each a different loosening of
that pattern. Where both the unused opt-out and the leaking command are
reported, both are asserted, each at its own line: a scanner that drops the
opt-out silently, or reports it yet still lets it excuse the run, gets only one
of them right. `bad/cleanup-optout-carry/` is a directory because only a second
file can show an opt-out carrying across the boundary.
`bad/cleanup-optout-after-rm.sh` indents its line and opens it with a removal
that uses up no keep, so a scanner that measures what precedes the second
command from the start of the line, rather than from the end of the first
command, reads only indentation there and lets the opt-out keep that run. The good opt-outs
indented with spaces and with tabs go red when a blank stops meaning either.

The real scans exclude this directory. If they ever stop excluding it, CI is red
forever and the reason is here.
