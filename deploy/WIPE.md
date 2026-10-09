# Wipe

The wipe policy is Nasir's, from the riftal-pm decision log's 2026-08-29 entry:
wipes between MVPs are allowed and announced in advance, and the last allowed
wipe is the one entering launch. This runbook is how the shared database is
wiped under that policy.

**Every wipe of the alpha or production database is real player data and runs
inside Nasir's gate, every time.** The loop runs `wipe-selftest.sh` and
nothing else.

## Scope

The shared MySQL database only. What a wipe does to world volumes and to
PocketMine's per-player data files (inventories) is not decided, so this
runbook does not touch them; riftal-pm#696 decides it. Until it is decided, a
wipe that clears balances and leaves inventories is a choice Nasir makes
knowingly, not a default.

## Why the schema is dropped, not emptied table by table

`wipe.sh` drops the database and recreates it empty, and the migrations
rebuild every table. No list of tables exists to fall behind the migrations.

The case that forced this is `economy_balance_snapshot` (riftal-pm ADR 006).
It is a derived copy of `balances` and `economy_ledger` with no foreign keys,
so clearing those two leaves it in place, and ADR 006 reads any non-empty
snapshot table as the valid snapshot. A snapshot surviving a wipe would claim
balances and ledger rows that no longer exist. After a wipe the table exists
and is empty, which ADR 006 reads as no valid snapshot.

Dropping the schema also removes the stored procedures and `schema_migrations`,
which the migrations recreate. MySQL roles and logins are server-level and
survive; the migration run reapplies their grants anyway.

## Steps

1. **Announce** the window in Discord, per the policy and `../CLAUDE.md`'s
   rollout rules.
2. **Stop every instance** with `stop` on stdin, waiting for the shutdown line.
   Never kill one. `wipe.sh` refuses while any other session is connected to
   the server, whatever its default database, but that check reads one moment
   and is a backstop, not a lock. Anything else holding a connection, such as
   a backup in progress or a client left open, must be closed too. See The
   session check, below.
3. **Back up.** One `backup.sh` run as in `README.md`. Note the set directory
   it prints as `backup <ts>: complete at <set>`. It is the rollback, and
   `wipe.sh` refuses without it. Retention prunes it after `BACKUP_RETENTION`
   more runs (2.5 days at the defaults); if it must be kept longer, copy it
   out of `BACKUP_ROOT` first, and where to is Nasir's call.
4. **Wipe.** `wipe.sh`, below, with the database named twice and the set from
   step 3. On success it prints
   `wipe <database>: complete, empty; run ../migrations/run-migrations.sh, then wipe-check.sh`.
5. **Migrate.** `../migrations/run-migrations.sh` with `GRANTS_FILE` and every
   `RIFTAL_DB_PASSWORD_<NAME>`, exactly as after a restore
   (`../migrations/README.md`).
6. **Verify.** `wipe-check.sh`, below. It fails unless `schema_migrations`
   records at least one migration and every other base table is empty, naming
   each table that is not (`wipe-check <database>: FAIL <table> holds <n>
   row(s)`). It passes with `wipe-check <database>: ok, <n> migration(s)
   applied, <n> table(s) all empty`.
7. **Start the instances**, one at a time, per `../CLAUDE.md`'s rollout order.

**Rollback**, at any step after 4: `restore.sh` with the step 3 set, then step
5. It also rebuilds every world volume from that set, which is the state they
were stopped in at step 2.

The binary log still holds the wiped rows for up to 30 days (`README.md`,
Binary log retention). A wipe does not purge it; purging it early deletes data
and is Nasir's.

## The session check

`wipe.sh` counts other sessions in `performance_schema.processlist`, and
refuses unless it can trust that count. It fails closed in three ways, each
printed as `wipe <database>: refused: <reason>`:

| Reason printed | Cause |
|---|---|
| `<user> lacks a direct PROCESS grant, so it cannot see every session` | Without `PROCESS` the processlist shows only the account's own threads, so it would count 0 whatever is connected. `PROCESS` held through a role is not seen, and refuses too |
| `the processlist does not show this session, so it cannot see the others; is performance_schema off?` | The count is trusted only once it shows the script's own connection. With `performance_schema` off the processlist is empty, and any other blindness looks the same |
| `<n> other session(s) are connected to <host>:<port>; close every other connection, instances first` | Every session counts whatever its default database, since any of them can write by qualified name. `Daemon` threads do not |

## Environment

`wipe.sh` and `wipe-check.sh` take `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`,
`MYSQL_PASSWORD` and `MYSQL_DATABASE` as in `README.md`. `wipe.sh` needs an
account that can drop and create the database and holds `PROCESS` granted
directly, not through a role. It also requires:

| Variable | Meaning |
|---|---|
| `WIPE_CONFIRM` | Must equal `MYSQL_DATABASE` exactly. There is no default |
| `BACKUP_SET` | The step 3 set. Its `mysql.sql` must be non-empty, and its `manifest.txt` must hold the line `mysql_database: <MYSQL_DATABASE>` and exactly one `timestamp:` line in `backup.sh`'s format, no older than `WIPE_BACKUP_MAX_AGE_MINUTES` and not in the future |
| `WIPE_BACKUP_MAX_AGE_MINUTES` | Optional, default `60`, see `README.md`. A whole number of minutes |

`wipe.sh` also refuses a database name outside `[A-Za-z0-9_]`, and a database
that does not exist. Every refusal happens before the drop, and leaves the
database as it was.

What a restore of the set would need, and `PROCESS` through a role, are open
in #498.

## Running it

On the dev stack, with the `mysql` service up and the variables set as in
`README.md`'s Running it locally:

```sh
wslc run --rm --network riftal-dev \
  -v "$INFRA/deploy:/deploy:ro" -v riftal-backups:/backups:ro \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE=riftal_dev -e WIPE_CONFIRM=riftal_dev \
  -e BACKUP_SET=/backups/<timestamp> \
  mysql:8 bash /deploy/wipe.sh
```

`wipe-check.sh` is the same command without `WIPE_CONFIRM`, `BACKUP_SET` and
the backups mount, running `/deploy/wipe-check.sh`. Wrap each in `timeout 120`
when running unattended.

## Testing

`wipe-selftest.sh` runs in CI (`.github/workflows/ci.yml`) against two
throwaway `mysql:8` containers that publish nothing, one of them with
`performance_schema` off; the header of the script says what it proves.
Locally, under the Docker in the WSL distro that hosts the CI runners:

```sh
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-26.04 -u runner --exec bash \
  /mnt/c/Users/nasir/riftal-games/riftal-infra/deploy/wipe-selftest.sh
```
