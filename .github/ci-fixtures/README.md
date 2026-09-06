# CI fixtures

Not part of the stack. Nothing here is ever built, run or deployed. These files
exist so `.github/scripts/selftest.sh` can feed each CI check input it must
reject and input it must accept.

`images/` and `proxy/` hold only a `.gitkeep` today, so the real scans in
`.github/workflows/ci.yml` find no files and pass by being empty. These fixtures
are what makes those checks provably able to fail on this commit rather than on
some future one.

Every file's first comment states the outcome it must produce. Change a check,
and change the fixture that covers it in the same commit, or the self-test goes
red. That is the intended behaviour.

`good/` is not decoration. A check that rejects a correct file is as broken as
one that accepts a wrong file, because the first person it blocks weakens it.

Each bad fixture carries exactly one defect and is asserted at exactly one site.
A fixture that trips several rules at once stays red when the rule it was
written for is switched off, so it keeps looking like coverage while pinning
nothing.

`good/stack.yaml` and `good/rollout.yml` are a pair, and they point in opposite
directions. One is compose under a name no convention would match, the other is
YAML with a `services` key that is nested rather than top level. Filename-based
discovery misses the first; matching `services` anywhere in the file claims the
second. Only a top-level key check gets both right.

The real scans exclude this directory. If they ever stop excluding it, CI is red
forever and the reason is here.
