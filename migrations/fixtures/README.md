# Migration runner fixtures

Not gameplay migrations. `riftal-game/lib/resources/sql/migrations/` is the
only real source of those; these exist only so `selftest.sh` can prove
`run-migrations.sh` against real files instead of an empty tree.

- `good/` applies cleanly, in order, and is what the idempotency and
  ordering assertions run against.
- `bad/` carries one valid file ahead of one deliberately broken one, so the
  self-test can assert both that the valid file is applied and recorded, and
  that the broken one stops the run without being recorded.
- `empty/` holds only a `.gitkeep`, standing in for a migrations directory
  with nothing pending yet.
- `race/` holds one file with a `SLEEP` in it, wide enough that two
  concurrent `run-migrations.sh` invocations racing the same lock name both
  land inside the window where the file still looks pending, so the
  self-test's lock-contention assertion has something to actually contend.
- `lostlock/` holds one file that KILLs the session holding the lock named
  `selftest-lost-lock`, so the self-test can lose the runner's lock mid-run
  without a timing race.
- `order/` holds three files that each create their own table, so the
  self-test can mark one as applied and show a lower pending file refused
  with nothing applied, and a higher one still applied.
- `collate/` holds `0001_B`, which creates a table, and `0001_a`, which
  fills it, so the pair applies only in bytewise order.
- `collate-locale/` holds a `sort` function, sourced through `BASH_ENV`, that
  folds case under any `LC_ALL` but `C`, standing in for a collating locale
  the `mysql:8` image does not carry.
- `grants/` holds a `grants.sql` standing in for `riftal-game`'s, creating
  `riftal_role_mines` with `SELECT` on the `good/` fixtures' `widgets`, so
  the self-test can provision a login against a real role.
- `definer/` creates `tallies` and `tallies_bump`, a procedure with the
  default `SQL SECURITY DEFINER`, the shape of `gangs_ledger_contribute`.
- `definer-grants/` creates `riftal_role_tally` with `SELECT` on `tallies` and
  `EXECUTE` on `tallies_bump`, and no `UPDATE`, so the self-test can show a
  login writing the table only through the procedure.
- `version-floor/` holds a shell function, sourced through `BASH_ENV`, that
  makes the runner's `VERSION()` query report a chosen version, so the
  self-test can show a server below 8.0.30 refused without one.
