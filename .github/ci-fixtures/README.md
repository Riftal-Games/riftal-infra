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

The scans exclude this directory. If they ever stop excluding it, CI is red
forever and the reason is here.
