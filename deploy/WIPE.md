# Wipe

The wipe policy is Nasir's, from the riftal-pm decision log's 2026-08-29 entry:
wipes between MVPs are allowed and announced in advance, and the last allowed
wipe is the one entering launch. This runbook is how the shared database and
every instance volume are wiped under that policy.

**Every wipe of the alpha or production database is real player data and runs
inside Nasir's gate, every time.** The loop runs `wipe-selftest.sh` and
`wipe-volumes-selftest.sh` and nothing else.

## Scope

A wipe clears everything a player could have changed, on every instance,
together, in one stopped-stack window (riftal-pm decision log, 2026-10-14,
riftal-pm#696). Clearing balances while inventories survive is not a valid
alpha wipe. It clears the shared database and, on each instance volume (the
instance's `/data`), the paths below, and nothing else:

| Path | Cleared | Ruling |
|---|---|---|
| The shared MySQL database | dropped, recreated and migrated | riftal-pm#696 |
| `worlds/<level>/`, each level | the whole folder | riftal-pm#696, #1309, #1312, #1314; see Levels, below |
| `players/` | its contents, the folder stays | riftal-pm#696 |
| `plugin_data/` | its contents, the folder stays | riftal-pm#1352 |

`plugin_data/` is cleared whole, with no list of subpaths: no plugin keeps
game state there, and every boot delivers again what this repo puts there,
so a later plugin that starts storing state in its folder cannot carry it
through a wipe (riftal-pm#1352). A config edited by hand on the volume is
lost with it; a setting that must outlive a wipe belongs in this repo's
committed files, delivered at boot. RiftalCapture empties `.capture/` itself
when it enables.

It never clears the volume root, never uses a glob or an "everything except"
rule, and leaves every other file byte for byte, including anything a later
core rebase starts writing there. These are kept on purpose (riftal-infra#1123,
decision log 2026-10-14), and the wipe neither clears nor refuses on them:

| Kept | Why |
|---|---|
| `crashdumps/` | Diagnostics, read when an incident is investigated, which a wipe window is |
| `server.log`, `log_archive/` | `custody-alert-check.sh` reads them as one record of process lifetimes across boots (`README.md`, Custody alert check) |
| `ops.txt` | Operator access for whoever runs the next alpha, a separate act with its own owner |
| `white-list.txt` | Who is in the next closed alpha, the same |
| `banned-players.txt`, `banned-ips.txt` | Clearing them would quietly pardon every banned player |

None of them holds an item, so hard rule 1 does not reach them. Clearing them
would protect no one's privacy either: the step 3 set tars each whole volume,
so every one is in the rollback set anyway. Whether alpha participants'
identity data in these files, the backup sets and the binary log is purged
after an alpha, and when, is Nasir's call; until he sets one, the wipe purges
none of it.

A rollback is not a wipe: `restore.sh` rebuilds every world volume from the
step 3 set (see Rollback).

## Levels

A level whose zone has an ADR 009 build, a `<zone>.lock.json` in
`designer/levels/`, is to be re-seeded from that build for the release being
entered. Re-seeding is riftal-infra#1126. Until it lands, `wipe.sh` refuses
on any volume holding a built level, and `wipe-check.sh` fails on one rather
than checking it against its lock's `content_sha256`.

A level with no build is cleared only on the shared dev stack, which takes two
keys, each matched exactly: `RIFTAL_DEV_ENV=1` in the wipe's own environment,
and a `MYSQL_DATABASE` of `riftal_dev` present on the server (riftal-pm#1314;
`../images/README.md`, Reserved for the dev stack). Anything else, one key
alone included, refuses and names the reason. After a dev wipe, core generates
each instance's default level fresh on its next boot. A non-default level is
left absent, and the ruling expects the first boot to log exactly one
`MineWorldLoader` WARNING per such level and no ERROR (riftal-pm#1312).

So today only the dev wipe completes. An alpha wipe refuses while any volume
holds a level, until each level an alpha instance loads has a build
(riftal-infra#1113) and re-seeding lands.

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
   Never kill one. The wipe clears their volumes, so none may be running to
   write to one. `wipe.sh` refuses while any other session is connected to
   the server, whatever its default database, but that check reads one moment
   and is a backstop, not a lock. Anything else holding a connection, such as
   a backup in progress or a client left open, must be closed too. See The
   session check, below.

   **Stop the `backup` service** too, and keep it stopped through step 7. Left
   running, a scheduled run between steps 4 and 7 stores a set of the empty
   database, takes one of the `BACKUP_RETENTION` slots, and brings the step 3
   set one run closer to being pruned. Stop it between runs, when its log's
   last run has reached `applying retention` and no `dumping database` line
   follows. The run holds its lock until its `pruning` lines, if any, are
   done, usually under a second, so wait a few seconds after the last line
   before stopping it. A run stopped part way leaves its `.lock` behind
   (`README.md`, Stale lock sweep), and step 3's run then fails until that
   lock is `LOCK_MAX_AGE_MINUTES` old.
3. **Back up.** One `backup.sh` run as in `README.md`. Note the set directory
   it prints as `backup <ts>: complete at <set>`. It is the rollback, and
   `wipe.sh` refuses without it. Retention prunes it in the run that leaves
   `BACKUP_RETENTION` newer sets. With `backup` stopped from step 2, the
   first of those is the run step 7 starts, so the set is gone
   `BACKUP_RETENTION - 1` intervals after step 7: 9 x 21600 s, 54 hours or
   about 2.25 days, at the defaults (`../images/compose.yaml`). Any other
   `backup.sh` run into the same `BACKUP_ROOT` brings that forward. If it
   must be kept longer, copy it out of `BACKUP_ROOT` before step 7, and where
   to is Nasir's call.
4. **Wipe.** `wipe.sh`, below, with the database named twice, the set from
   step 3, and every instance volume mounted read-write under `WORLDS_DIR`
   by the same names the `backup` service mounts them by. Every check, on
   the database and on every volume, runs before anything is cleared, so a
   refusal leaves the database and every volume as they were. On success it
   prints, for each volume,
   `wipe <database>: volume <name>: cleared <n> level(s) and the contents of players/ and plugin_data/`,
   then drops the database and ends with
   `wipe <database>: complete, empty; run ../migrations/run-migrations.sh, then wipe-check.sh`.
5. **Migrate.** `../migrations/run-migrations.sh` with `GRANTS_FILE` and every
   `RIFTAL_DB_PASSWORD_<NAME>`, exactly as after a restore
   (`../migrations/README.md`).
6. **Verify.** `wipe-check.sh`, below, before any instance starts, since a
   boot writes a default level back. Mount every volume step 4 mounted, by
   the same names: it checks only the volumes under `WORLDS_DIR` and passes
   on those, so a volume left unmounted goes unchecked with nothing printed
   about it. Each clean volume prints `wipe-check <database>: volume <name>:
   ok, no level, and players/ and plugin_data/ hold no file`. It fails on
   any level still present (`FAIL level <zone> on <name> ...`), on any file
   in `players/` or `plugin_data/` (`FAIL <dir>/ on <name> holds <n>
   file(s)`), when `schema_migrations` records no migration, when the table
   list cannot be read (`FAIL could not list the tables in <database>`) or
   names no table but `schema_migrations` (`FAIL information_schema lists no
   table but schema_migrations, ...`), and on each other base table that is
   not empty (`FAIL <table> holds <n> row(s)`).
   `capture_fence` is the exception: riftal-game's migration 0027 seeds its
   one row, lowered, so it must hold exactly that row, and fails with `FAIL
   capture_fence should hold only migration 0027's row, id 1 and lowered; it
   holds <n> row(s), <n> of them that row`. It passes with `wipe-check
   <database>: ok, <n> migration(s) applied, <n> table(s) empty but for <n>
   seeded row(s)`. A built level fails it until riftal-infra#1126 lands.
7. **Start the instances**, one at a time, per `../CLAUDE.md`'s rollout order,
   then start the `backup` service. `backup-loop.sh` runs `backup.sh` at once
   on start, so the first set after the wipe is taken then.

**Rollback**, once step 4 has dropped the database: repeat step 2 first if any
instance or the `backup` service is running, since `restore.sh` makes no
session check before it drops the database and clears every world volume. Then
`restore.sh` with the step 3 set, then step 5, then step 7. It rebuilds every
world volume from that set, which is the state they were stopped in at step 2,
so a rollback after step 7 also discards every block changed and every row
written since the instances came back.

**A run that stops before step 4**, for example because `wipe.sh` refused,
has dropped and cleared nothing and needs no rollback. Every instance and the `backup`
service are still stopped from step 2, so go straight to step 7.

The binary log holds every change written in the last 30 days, the wiped
rows' history among them (`README.md`, Binary log retention). A row last
written before that window may be in no binary log, only in the step 3 set.
A wipe does not purge the log; purging it early deletes data and is Nasir's.

## The session check

`wipe.sh` counts other sessions in `performance_schema.processlist`, and
refuses unless it can trust that count. It fails closed in three ways, each
printed as `wipe <database>: refused: <reason>`:

| Reason printed | Cause |
|---|---|
| `<user> lacks PROCESS, directly or through an active role, so it cannot see every session` | Without `PROCESS` the processlist shows only the account's own threads, so it would count 0 whatever is connected. It is read from `SHOW GRANTS` in the same session as the count, so `PROCESS` through a role counts only when that role is active at login, as a default role is |
| `the processlist does not show this session, so it cannot see the others; is performance_schema off?` | The count is trusted only once it shows the script's own connection. With `performance_schema` off the processlist is empty, and any other blindness looks the same |
| `<n> other session(s) are connected to <host>:<port>; close every other connection, instances first` | Every session counts whatever its default database, since any of them can write by qualified name. `Daemon` threads do not |

## Environment

`wipe.sh` and `wipe-check.sh` take `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`,
`MYSQL_PASSWORD` and `MYSQL_DATABASE` as in `README.md`. `wipe.sh` needs an
account that can drop and create the database and holds `PROCESS`, granted
directly or through a default role. Both scripts require:

| Variable | Meaning |
|---|---|
| `WORLDS_DIR` | The directory every instance volume is mounted under, one subdirectory each, as for `backup.sh`. There is no default here. Read-write for `wipe.sh`; `wipe-check.sh` only reads |
| `LEVEL_LOCKS_DIR` | A directory holding each ADR 009 build's `<zone>.lock.json`: `designer/levels/`, mounted in |

`wipe.sh` also requires:

| Variable | Meaning |
|---|---|
| `WIPE_CONFIRM` | Must equal `MYSQL_DATABASE` exactly. There is no default |
| `RIFTAL_DEV_ENV` | `1` on the shared dev stack only, and never set on any other (see Levels). Without it a level with no build refuses |
| `BACKUP_SET` | The step 3 set. Its `mysql.sql` must be non-empty, and its `manifest.txt` must hold the line `mysql_database: <MYSQL_DATABASE>` and exactly one `timestamp:` line in `backup.sh`'s format, no older than `WIPE_BACKUP_MAX_AGE_MINUTES` and not in the future. It must also pass the checks `restore.sh` makes before touching anything, since it is the rollback: a `worlds/` directory holding at least one `.tar.gz`, each of which lists with `tar -tzf` |
| `WIPE_BACKUP_MAX_AGE_MINUTES` | Optional, default `60`, see `README.md`. A whole number of minutes |

`wipe.sh` also refuses a database name outside `[A-Za-z0-9_]`, a database
that does not exist, no volume under `WORLDS_DIR`, a tar in the set with no
volume of its name under `WORLDS_DIR`, and a volume with no tar of its name
in the set. Every refusal happens before the drop and before any volume is
cleared, and leaves both as they were.

## Running it

On the dev stack, with the `mysql` service up, both instances stopped, and
the variables set as in `README.md`'s Running it locally. Mount both instance
volumes as the `backup` service does:

```sh
wslc run --rm --network riftal-dev \
  -v "$INFRA/deploy:/deploy:ro" -v riftal-backups:/backups:ro \
  -v "$INFRA/designer/levels:/levels:ro" \
  -v riftal-world:/worlds/riftal-world -v riftal-world-b:/worlds/riftal-world-b \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE=riftal_dev -e WIPE_CONFIRM=riftal_dev -e RIFTAL_DEV_ENV=1 \
  -e BACKUP_SET=/backups/<timestamp> -e WORLDS_DIR=/worlds -e LEVEL_LOCKS_DIR=/levels \
  mysql:8 bash /deploy/wipe.sh
```

Then, after the migrations, the check, with the same volumes read-only:

```sh
wslc run --rm --network riftal-dev \
  -v "$INFRA/deploy:/deploy:ro" -v "$INFRA/designer/levels:/levels:ro" \
  -v riftal-world:/worlds/riftal-world:ro -v riftal-world-b:/worlds/riftal-world-b:ro \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE=riftal_dev -e WORLDS_DIR=/worlds -e LEVEL_LOCKS_DIR=/levels \
  mysql:8 bash /deploy/wipe-check.sh
```

Any other stack drops `RIFTAL_DEV_ENV`, names its own database twice, and
mounts every one of its instance volumes in both commands. Wrap each in
`timeout 120` when running unattended.

## Testing

`wipe-selftest.sh` runs in CI (`.github/workflows/ci.yml`) against two
throwaway `mysql:8` containers that publish nothing, one of them with
`performance_schema` off; the header of the script says what it proves.
CI does not check out riftal-game, so its migrations stand in for the real
ones, with `capture_fence` and its seeded row copied from 0027.
`wipe-volumes-selftest.sh` covers the volumes on throwaway `riftal_smoke_*`
volumes, every file Scope keeps among them, byte for byte. Locally, under the Docker in the WSL distro that hosts the CI runners:

```sh
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-26.04 -u runner --exec bash \
  /mnt/c/Users/nasir/riftal-games/riftal-infra/deploy/wipe-selftest.sh
```
