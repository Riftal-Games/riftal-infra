# CI fixtures

Not part of the stack. Nothing here is ever built, run or deployed. These files
exist so `.github/scripts/selftest.sh` can feed each CI check input it must
reject and input it must accept.

`images/` and `proxy/` hold only a `.gitkeep` today, so the real scans in
`.github/workflows/ci.yml` find no files and pass by being empty. These fixtures
are what makes those checks provably able to fail on this commit rather than on
some future one.

Every file's first comment states the finding it must produce. If you change a
rule in `check_port_policy.py`, change the fixture that covers it in the same
commit, or the self-test goes red, which is the intended behaviour.

`good/` is not decoration. A rule that fires on `mkdir -p` is as broken as a
rule that misses a publish, because the first person it blocks weakens it, so
`good/ops.sh` must stay clean for the same reason `bad/run-instance.sh` must
stay red.

The pairs are chosen so that no rule can be judged by a fixture that shares its
mechanism. `good/run-proxy.sh` passes because its `--name` is the proxy, and
`bad/run-downstream-proxy-net.sh` fails despite the word proxy being on the
line: one fixture wants the classifier to say yes and the other wants it to say
no, so a rule that went back to reading the whole line flips exactly one of
them and the self-test names it.

In a fixture with more than one command, each asserted code belongs to exactly
one of them. A file where any single command carries every asserted code stays
green when the other commands are neutered, so it stops pinning the thing it
was written for while still looking like coverage.

The scans exclude this directory. If they ever stop excluding it, CI is red
forever and the reason is here.
