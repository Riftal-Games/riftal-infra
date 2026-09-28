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
- `grants/` holds a `grants.sql` standing in for `riftal-game`'s, creating
  `riftal_role_mines` with `SELECT` on the `good/` fixtures' `widgets`, so
  the self-test can provision a login against a real role.
