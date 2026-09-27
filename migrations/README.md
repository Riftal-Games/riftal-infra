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

Wrap the `wslc run` above in `timeout 120` when running it unattended: if the
lock cannot be acquired, this hangs for `MIGRATIONS_LOCK_TIMEOUT` seconds
before failing loudly, and a hung `wslc` call otherwise gives no signal.

## Testing

`selftest.sh` proves the runner against a real, throwaway `mysql:8`
container using the fixtures in `fixtures/`: no-op on an empty directory,
ordered apply with both files recorded, a no-op second run, and a broken
migration halting the run without being recorded. It calls `docker` directly,
the same way `.github/workflows/ci.yml`'s PHP lint step already does, so it
runs in CI and is **not runnable on Nasir's Windows machine**, which has no
docker, only `wslc`. The `wslc` command above is how this runner is actually
exercised locally.
