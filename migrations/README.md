# Shared schema migration runner

Runs pending migrations against the one shared MySQL database, under a MySQL
named lock. The lock matters because more than one instance container can
boot at once against that database, and simultaneous boots are more likely
under containers, not less (CLAUDE.md hard rule 5).

`run-migrations.sh` is the whole tool. It:

1. Acquires `GET_LOCK('riftal_schema_migrations', <timeout>)` over a
   connection it holds for the whole run, and releases it on the way out,
   success or failure.
2. Refuses, before writing anything, a server whose `VERSION()` is below
   MySQL 8.0.30, the floor ADR 008 sets because `grants.sql` may use
   `REVOKE IF EXISTS`. The `mysql:8` tag floats, so the server is asked.
3. Reads `*.sql` files from `MIGRATIONS_DIR`, sorted by filename under
   `LC_ALL=C`, and applies the ones not already recorded in a
   `schema_migrations` bookkeeping table. The order is bytewise whatever
   locale the container carries, so `0001_B` sorts before `0001_a` on every
   image.
   A missing or empty directory is nothing pending, not a fault: there is no
   table to migrate until `riftal-game` ships one.
   It refuses the whole run, with a nonzero exit and nothing applied, when
   any pending file sorts below the highest already recorded one, naming
   both. That database would otherwise run the file after the higher one
   while a fresh database runs it before, and the two could end with
   different schemas. A lower number that lands late is renumbered above the
   highest applied, never forced in.
4. Stops on the first migration that errors, with a nonzero exit and that
   file left unrecorded. A later run retries it and everything after it.
   Before exiting it still applies `GRANTS_FILE`, past any statement that
   errors, because a file before the failed one may have dropped and
   recreated a procedure, and that drops every role's `EXECUTE` on it.
5. Is a no-op success when nothing is pending, so running it twice is safe.
6. Provisions the per-plugin MySQL logins of ADR 008 (riftal-pm
   `docs/decisions/008-per-plugin-mysql-users.md`) on every run, still under
   the same lock. See Provisioning logins below.

Migration files themselves are authored in
`riftal-game/lib/resources/sql/migrations/` (riftal-game#21). This repo only
runs them; it never authors gameplay migrations.

## Environment

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `MYSQL_HOST` | yes | | Database host, the container network alias in this stack (`mysql`) |
| `MYSQL_PORT` | no | `3306` | |
| `MYSQL_USER` | no | `root` | |
| `MYSQL_PASSWORD` | yes | | Read via `MYSQL_PWD` internally so it never appears in `ps` output |
| `MYSQL_DATABASE` | yes | | `riftal_dev` in the local stack |
| `MIGRATIONS_DIR` | no | sibling checkout's `riftal-game/lib/resources/sql/migrations` | Mount the real directory in explicitly rather than relying on the fallback |
| `MIGRATIONS_LOCK_NAME` | no | `riftal_schema_migrations` | Override only for running more than one independent test in parallel |
| `MIGRATIONS_LOCK_TIMEOUT` | no | `60` (seconds) | |
| `GRANTS_FILE` | no | sibling checkout's `riftal-game/lib/resources/sql/grants.sql` | Mount the real file in explicitly, as with `MIGRATIONS_DIR` |
| `RIFTAL_DB_PASSWORD_<NAME>` | no | | One per plugin login to provision, e.g. `RIFTAL_DB_PASSWORD_MINES` for `mines`. At least 24 characters, `[A-Za-z0-9]` only |

## Provisioning logins

After the migrations, every run:

1. Applies `GRANTS_FILE`, which creates the `riftal_role_*` roles and their
   privileges. A missing file is skipped only when neither `GRANTS_FILE` nor
   any `RIFTAL_DB_PASSWORD_*` is set, and fails the run otherwise, before
   anything connects. Grants are never recorded
   as applied: a dump restored onto a fresh server carries
   `schema_migrations` but no roles, so they are rebuilt every run.
2. For each `RIFTAL_DB_PASSWORD_<NAME>`, runs `CREATE USER IF NOT EXISTS` and
   then `ALTER USER` for `'<name>'@'%'`, so the environment always decides the
   password. Rotating one is changing the variable and running this again.
3. Grants `riftal_role_<name>` to the login and sets it as the default role.

It fails loudly, before touching anything, on a password under 24 characters
or with a character outside `[A-Za-z0-9]`, and, before creating any login, on
a login whose `riftal_role_<name>` does not exist as a role. No password is ever
printed. It is not a `/docker-entrypoint-initdb.d` script: it runs wherever
migrations run, including after every `../deploy/restore.sh`.

## Stored procedures and their definer

A migration that creates a procedure, such as riftal-game's
`gangs_ledger_contribute` (`0009_create_gang_ledger.sql`, redefined in
`0010_add_gang_founded_marker.sql`), leaves MySQL's default
`SQL SECURITY DEFINER` in place, per ADR 008. Its definer is the account this
runner connected as: `MYSQL_USER`, which defaults to `root`, reached over the
container network, so `root`@`%`. Three things follow. `selftest.sh` proves
each against a fixture procedure, and `../deploy/restore-selftest.sh` proves
the third through the real backup and restore scripts.

**A login needs only `EXECUTE`.** The procedure body runs with the definer's
privileges, so a plugin role holds `EXECUTE` on the procedure and nothing on
the columns it writes. A direct `UPDATE` by the same login is refused.
riftal-game's `grants.sql` (riftal-game#259) must carry `GRANT EXECUTE ON
PROCEDURE gangs_ledger_contribute TO riftal_role_gangs` (ADR 008, item 2).
Until it does, no provisioned login can call the procedure. Grants are
reapplied on every run, so a restore rebuilds this one too.

**The definer account is never dropped or renamed.** MySQL resolves the
definer on every call. Once `root`@`%` is gone, every call fails with
`ERROR 1449 ... The user specified as a definer ('root'@'%') does not exist`,
on every instance at once. `root`@`localhost` is a separate account and does
not stand in for it. Running migrations as a different account later does not
move an existing procedure: it keeps its definer until a new migration drops
and recreates it, so the old account stays until then.

**Backups keep routines.** `mysqldump` leaves procedures out unless it is
given `--routines`. Without them, a restore carries `schema_migrations` saying
`0009` and `0010` ran and no procedure, and this runner never recreates it.
`../deploy/backup.sh` passes `--routines --triggers`. The dump writes each
procedure as ``CREATE DEFINER=`root`@`%` PROCEDURE``, so the server restored
into must have that account before the first call. `../deploy/restore.sh`
loads the dump as `MYSQL_USER`, default `root`, which must be `root` or another
account allowed to create a routine under any definer.

## Running it locally, via `wslc`

Same `mysql:8` image the dev stack already runs, so nothing new to pull.
Run this after `riftal-mysql` is up and **before** the instance, per the
rollout order in `../CLAUDE.md`: migrations, then instances, then the proxy.

```sh
export MSYS_NO_PATHCONV=1
INFRA=C:/Users/nasir/riftal-games/riftal-infra
GAME=C:/Users/nasir/riftal-games/riftal-game
set -a; . "$INFRA/images/.env"; set +a

wslc run --rm --network riftal-dev \
  -v "$INFRA/migrations/run-migrations.sh:/run-migrations.sh:ro" \
  -v "$GAME/lib/resources/sql/migrations:/migrations:ro" \
  -v "$GAME/lib/resources/sql/grants.sql:/grants.sql:ro" \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE=riftal_dev -e MIGRATIONS_DIR=/migrations -e GRANTS_FILE=/grants.sql \
  mysql:8 bash /run-migrations.sh
```

To provision logins in the same run, add one name-only `-e RIFTAL_DB_PASSWORD_<NAME>` per login, exported in the
shell first, so the password stays off the host's command line. Until
`riftal-game` ships `grants.sql` (riftal-game#259), the bind mount creates an
empty directory in its place, and the runner refuses it: any run that sets
`GRANTS_FILE` or a `RIFTAL_DB_PASSWORD_*` exits nonzero unless the grants
file is a readable regular file. Only a run setting neither skips grants.

Wrap the `wslc run` above in `timeout 120` when running it unattended: if the
lock cannot be acquired, this hangs for `MIGRATIONS_LOCK_TIMEOUT` seconds
before failing loudly, and a hung `wslc` call otherwise gives no signal.
The failure names the holder: its connection id from `IS_USED_LOCK`, and the
user and host from that connection's row in `performance_schema.processlist`,
which needs no grant but shows a login without `PROCESS` only its own
sessions. An empty row is reported as could not be read, since a hidden row
and a holder that disconnected between the two reads look the same. Only a
`GET_LOCK` answer of `0` is reported as a timeout; `NULL` is an error.

## Testing

`selftest.sh` proves the runner against a real, throwaway `mysql:8`
container using the fixtures in `fixtures/`: no-op on an empty directory,
ordered apply with both files recorded, a no-op second run, a broken
migration halting the run without being recorded, a migration failing after
one that recreated a procedure still restoring the role's `EXECUTE` on it, a
pending file sorting
below the highest applied one refusing the run while files above it still
apply, both of those decided bytewise under a stand-in case-folding locale,
and two invocations racing
the same lock name applying a pending migration exactly once, a lock held
by another login timing out with that login named, each unusable read
of the holder reported as what it is (a `GET_LOCK` NULL, an `IS_USED_LOCK`
NULL or failure, a failed processlist query, and the empty row a login
without `PROCESS` or any `performance_schema` grant reads), a server
reporting 8.0.29 refused while 8.0.30 and 8.1.0 pass, and login
provisioning against `fixtures/grants/`: a login created on an existing
schema, an idempotent second run, rotation, a restore onto a fresh server,
and the loud refusals, and the DEFINER procedure checks above. It calls
`docker` directly, the same way `.github/workflows/ci.yml`'s PHP lint step
does, so it runs in CI and, on Nasir's Windows machine, under the Docker
inside the WSL distro that hosts the CI runners:

```sh
wsl -d Ubuntu-26.04 -u runner --exec bash /mnt/c/Users/nasir/riftal-games/riftal-infra/migrations/selftest.sh
```

Each run writes its logs to its own `mktemp -d` directory and removes it on
exit, so concurrent runs on one host do not clobber each other.
