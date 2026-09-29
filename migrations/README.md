# Shared schema migration runner

Runs pending migrations against the one shared MySQL database, under a MySQL
named lock. The lock matters because more than one instance container can
boot at once against that database, and simultaneous boots are more likely
under containers, not less (CLAUDE.md hard rule 5).

`run-migrations.sh` is the whole tool. It:

1. Acquires `GET_LOCK('riftal_schema_migrations', <timeout>)` over a
   connection it holds for the whole run, and releases it on the way out,
   success or failure.
2. Reads `*.sql` files from `MIGRATIONS_DIR`, sorted by filename, and applies
   the ones not already recorded in a `schema_migrations` bookkeeping table.
   A missing or empty directory is nothing pending, not a fault: there is no
   table to migrate until `riftal-game` ships one.
3. Stops on the first migration that errors, with a nonzero exit and that
   file left unrecorded. A later run retries it and everything after it.
4. Is a no-op success when nothing is pending, so running it twice is safe.
5. Provisions the per-plugin MySQL logins of ADR 008 (riftal-pm
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
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE=riftal_dev -e MIGRATIONS_DIR=/migrations \
  mysql:8 bash /run-migrations.sh
```

To provision logins in the same run, add
`-v "$GAME/lib/resources/sql/grants.sql:/grants.sql:ro" -e GRANTS_FILE=/grants.sql`
and one name-only `-e RIFTAL_DB_PASSWORD_<NAME>` per login, exported in the
shell first, so the password stays off the host's command line. Until
`riftal-game` ships `grants.sql` (riftal-game#259), the bind mount creates an
empty directory in its place, and the runner refuses it: any run that sets
`GRANTS_FILE` or a `RIFTAL_DB_PASSWORD_*` exits nonzero unless the grants
file is a readable regular file. Only a run setting neither skips grants.

Wrap the `wslc run` above in `timeout 120` when running it unattended: if the
lock cannot be acquired, this hangs for `MIGRATIONS_LOCK_TIMEOUT` seconds
before failing loudly, and a hung `wslc` call otherwise gives no signal.

## Testing

`selftest.sh` proves the runner against a real, throwaway `mysql:8`
container using the fixtures in `fixtures/`: no-op on an empty directory,
ordered apply with both files recorded, a no-op second run, a broken
migration halting the run without being recorded, and two invocations racing
the same lock name applying a pending migration exactly once, and login
provisioning against `fixtures/grants/`: a login created on an existing
schema, an idempotent second run, rotation, a restore onto a fresh server,
and the loud refusals. It calls
`docker` directly,
the same way `.github/workflows/ci.yml`'s PHP lint step does, so it runs in
CI and, on Nasir's Windows machine, under the Docker inside the WSL distro that
hosts the CI runners:

```sh
wsl -d Ubuntu-26.04 -u runner --exec bash /mnt/c/Users/nasir/riftal-games/riftal-infra/migrations/selftest.sh
```

Each run writes its logs to its own `mktemp -d` directory and removes it on
exit, so concurrent runs on one host do not clobber each other.
