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

Each bad fixture carries exactly one defect and is asserted at exactly one site.
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

The real scans exclude this directory. If they ever stop excluding it, CI is red
forever and the reason is here.
