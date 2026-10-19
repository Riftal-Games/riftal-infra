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
`bad/lowercase/` holds both again under all-lowercase names, and
`good/uppercase-extension.YAML` and `good/uppercase-extension.YML` are compose
under each uppercase extension, so discovery that matches a name
case-sensitively goes red. `bad/lowercase/` is a
directory because a case-insensitive checkout cannot hold `dockerfile` beside
`Dockerfile`.

`good/stack.yaml` and `good/rollout.yml` are a pair, and they point in opposite
directions. One is compose under a name no convention would match, the other is
YAML with a `services` key that is nested rather than top level. Filename-based
discovery misses the first; matching `services` anywhere in the file claims the
second. Only a top-level key check gets both right.

`good/ports.compose.yaml` and the three `bad/ports-*.compose.yaml` drive
`scan.sh ports`, the port policy in `.github/scripts/check_port_policy.py`. Each
bad file trips one rule and is asserted on its exact finding count, so deleting
any one rule turns exactly one assertion red. `bad/ports-wide-bind.compose.yaml`
holds its second wide bind behind a profile, so a scan that stops asking compose
for every profile reports one finding there instead of two. `good/compose.yaml`
is a compose validity fixture only and is not held to the port policy.

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
word above. `bad/cleanup-eof-continued/` is a directory of two files that each
end on a continued run, so whichever is read first loses its run at the next
file's first line and the other at the end of input, and a scanner that checks
the pending command at only one of those two points names only one file.

A run or create reads its options only up to the image, so
`bad/cleanup-rm-after-image.sh` puts each `--rm` after the image, behind a
short, a long, a clustered, an attached and an `=` option in turn, so a scanner
that lets any of those swallow the image goes red. `good/cleanup.sh` puts its
`--rm` behind options that take a value in each form docker reads one, so a
scanner that stops at a value as if it were the image goes red there.
`bad/cleanup-rm-quoted-value.sh` hides each `--rm` inside a single or double
quoted value, so a scanner that splits words on blanks without reading quotes
goes red, and `good/cleanup.sh` follows quoted values holding a blank, a
backslash and the other quote with a real `--rm`.

A flag after a trailing `#` lends a command nothing, but the scanner never
deletes the text after a `#`: it only stops looking for that command's flags
there, so a `#` it misreads can report a command and never hide one.
`bad/cleanup-comment*.sh` and `bad/cleanup-continued-comment.sh` put the flag
in a comment, and `bad/cleanup-comment-twice.sh` follows the flag with a second
`#`, so a scanner that cuts at the last `#` goes red. Every `bad/cleanup-hash-*.sh` puts a `#` that a shell reads as
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

`good/action-pins/` and `bad/action-pins/` drive `.github/scripts/action-pins.sh`.
Each workflow sits under its own `.github/workflows/`, and the composite action is
named `action.yml`, so the same discovery the real tree gets finds them. The good
workflow is asserted with its exact count of `uses:` lines checked, because a check
that stops recognising one spelling of the key passes a good file just as well.
`bad/action-pins/` has one bad file per way a ref fails to pin: a tag quoted each
way, a branch, a short, long or uppercase sha, a sha only in the trailing comment,
a word after the sha that YAML reads into the ref, a URL ending in a sha, no ref at
all and a `docker://` tag, and the list, mapping and spaced-key forms of the key
are spread across them. Two more carry a tag behind a key quoted each way, and four
hold a pinned sha in a flow collection, because a flow collection fails whatever it
names: one after a comma, one with the `{` opening its line, one with a quoted key
after the `{`, and one directly behind the `[` of a flow sequence, which YAML reads
as a single-pair mapping. Six more hold a pinned sha behind a key form the script
does not read, each of which fails whatever it names: an explicit `?` key, a tag,
an anchor, a double-quoted key spelled with an escape, a second `-`, and an alias
used as a key. Four more put those forms where a narrower pattern would miss them:
a tag after the `[` of a flow sequence, a quoted key behind a tag, an explicit `?`
after a `{` with the key on the next line, and an alias directly after a `{`.
Eight more do the same: an anchor, and a tag with an anchor, after the `[` of a
flow sequence; an explicit `?` after a `[`, and after a `,`, with the key on the
next line; a single-quoted key behind a tag; an alias directly after a `[`, and
directly after a `,`; and an alias key with its value on the next line. The script
refuses each of these, so a check that stops refusing one exits 0 there. Three more
each hold up one pattern alternative that no file above needs, so dropping it exits
0 at that file: no space between the `?` and a uses key in a flow mapping, the same
with an alias, both of which PyYAML reads as explicit keys, and an alias key at
column 0 on a continuation line of a flow collection. Two more put that unspaced
`?` and uses key after a `{` with the value on the next line, one with nothing
after the key and one with a comment after it, so the script must refuse the key
without a `:` behind it on its line. Two more open a continuation
line of a flow mapping with a `?` and a uses key and no space between them, which
PyYAML reads as an explicit key: one with the value on the same line, and one with
the value on the next line and a comment after the `,` before it, so the script
must find that `,` past the comment. Seven more open such a line the same way, each
for one part of how the script reads it: after a line ending in a `{`, and after
one ending in a `[`; after a `,` with trailing spaces behind it; with a tag, and
with an anchor, between the `?` and the key; and with the key double-quoted, and
single-quoted. Two more open such a line indented, and after a blank line behind
the `,`, so the script must allow leading space before the `?` and must look past a
blank line for the `,`. Five more open it the same way: with a comment after the
key and the value on the next line; after a `,` behind a scalar holding a blank and
a `#`, double-quoted, single-quoted, and double-quoted with a comment after the
`,`; and after a double-quoted scalar whose second line opens with a `#` and ends
in the `,`. So the script must not cut a line at a `#` it cannot tell from one
inside quotes, nor skip a line only because it looks like a comment. One more
has three blanks followed by a `#` on the line before, with the `,` behind the
first, so the script must test every cut, not only the last one. The good
workflow keeps comment lines holding `{ uses: ... }`, so a check that stops
exempting a comment goes red there, and a `?uses` key in a block plus a `?with` key
opening a flow continuation line, so a check that refuses every line opening with a
`?` goes red there too. The URL is there for the pattern's start anchor and the
trailing word for the check on what follows the value: without either, a sha at the
end of the line passes.

`good/job-timeouts/` and `bad/job-timeouts/` drive the function in
`.github/scripts/job-timeouts.sh` through `job-timeouts-selftest.sh`, which
ci.yml runs before any container starts. Each is asserted on its exit and its
exact reason line under a 1200-second cutoff, and the self-test counts one
assertion per file directly in those two directories, plus one for a missing
path. The bad files are a job with no `timeout-minutes`, a job whose only one is
on a step, an expression value, a value equal to the cutoff, a value over it
written with a leading zero, which shell arithmetic would read as octal and
under it, an untimed job beside a call carrying a timeout, so a check that
counts instead of pairing goes red, a job with neither `runs-on` nor `uses`,
jobs indented too deep to find, a call to another repository, a call whose
called job is untimed, a call that loops on itself, and a call into two files
that call each other, which only the call chain catches. Each assertion runs
under a 10-second `timeout`, so a check that follows a loop forever fails there
instead of holding the job.

The good files are two jobs, the longer one minute under the cutoff, with a step
timeout over it, so a check that reads a step's timeout as its job's goes red
there, a call whose called job sets the longest timeout, two calls to the same
file that itself calls a deeper one, so a check that leaves a returned call on
the chain refuses the second call as a loop, and a top-level key after `jobs:`
with a child indented two spaces, so a check that does not end the jobs block
there reads that child as a job. A called file lives in its caller's directory
under `.github/workflows/`, where a `./` call resolves, and is never asserted on
its own.

`fake-locale-sort.bash` is a `sort` function the Dockerfile order check loads
through `BASH_ENV`. It folds case under any collating locale and keeps C order
under C, so a scan.sh that drops its `LC_ALL=C` goes red on any host, whether
its `sort` is GNU or uutils and whatever locales it carries.

The real scans exclude this directory. If they ever stop excluding it, CI is red
forever and the reason is here.
