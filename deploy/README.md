# Backup and restore

`backup.sh` takes one coordinated snapshot of the shared MySQL database and
every instance's world volume, close enough in time that restoring both
together does not produce an inconsistent state (the `riftal-pm` workspace's
`docs/specs/008-backup-and-restore.md`). `backup-loop.sh` runs it on a
schedule. `restore.sh` rebuilds both from one chosen backup set.

## What one run produces

Under `BACKUP_ROOT` (`/backups` in the `backup` service), one timestamped
directory per run, `<UTC timestamp>/`, holding:

- `mysql.sql`, a `mysqldump --single-transaction` of the shared database.
- `worlds/<volume-name>.tar.gz`, one per world volume found under
  `WORLDS_DIR` (`/worlds`) at run time.
- `manifest.txt`, the timestamp, the database name, and every artifact's
  byte size, so an operator can inspect one run without extracting anything.

A run that fails at any point removes its own partial directory and exits
nonzero rather than leaving a half-written set behind for retention to count
as a real backup.

`backup.sh` never hardcodes which volumes exist or how many; it tars whatever
subdirectories `WORLDS_DIR` holds. What appears there is decided by
`images/compose.yaml`'s `backup` service, which mounts one read-only path per
instance world volume. Splitting a world onto a new instance (`/add-instance`)
adds one line there; the script needs no change, per `CLAUDE.md` hard rule 5.

## Retention

`BACKUP_RETENTION` (default 10, see `images/.env.example`) is how many backup
sets survive. After a successful run, `backup.sh` lists `BACKUP_ROOT`'s
subdirectories, oldest first, and removes whichever are beyond that count.
Pruning only happens after a run succeeds, so a failed run never deletes a
good backup to make room for the one it never produced.

## Schedule

`backup-loop.sh` runs `backup.sh` once, then every `BACKUP_INTERVAL_SECONDS`
(default 21600, six hours), forever, inside the `backup` compose service. A
failed run is logged and the loop keeps going, so one bad run does not cost
every backup after it until someone notices the container died.

## Restore

`restore.sh` rebuilds the shared MySQL database and every world volume from
one specific backup set named by `BACKUP_SET` (a directory `backup.sh`
produced, e.g. `/backups/20260928T120000000000000Z`). There is no "latest"
default: an operator restoring after a bad deploy or a corrupted world is
often trying to get back to a point *before* the most recent backup, and a
default that silently picks the newest one can restore straight back into
the bad state.

A restore is destructive by design, not incremental:

- The target database is dropped and recreated before the dump loads, so a
  stale row or table the backup no longer knows about (the dump was taken
  without `--add-drop-table`) cannot survive a restore.
- Each target world directory is cleared before its tar extracts, so a file
  written since the backup (a block broken afterward, a corrupted region
  file) cannot survive next to the restored one.

Both are rebuilt to exactly what the chosen backup set describes, nothing
merged on top.

Before any of that, `restore.sh` lists every world tar in the set with
`tar -tzf` and fails loudly if any one of them does not extract cleanly. This
runs before the database is touched and before any target directory is
cleared, so a corrupt tar for one world in a multi-world set aborts the whole
restore instead of being found only after earlier worlds have already been
cleared and left neither restored nor in their pre-restore state.

## Environment

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `MYSQL_HOST` | yes | | Database host, `mysql` in this stack |
| `MYSQL_PORT` | no | `3306` | |
| `MYSQL_USER` | no | `root` | |
| `MYSQL_PASSWORD` | yes | | Read via `MYSQL_PWD` internally, same as `../migrations/run-migrations.sh` |
| `MYSQL_DATABASE` | yes | | `riftal_dev` in the local stack |
| `BACKUP_ROOT` | no | `/backups` | Where backup sets land; must be a volume, never the container's own layer |
| `WORLDS_DIR` | no | `/worlds` | Parent of one subdirectory per world volume |
| `BACKUP_RETENTION` | no | `10` | Backup sets kept before pruning |
| `BACKUP_INTERVAL_SECONDS` | no | `21600` | `backup-loop.sh` only |
| `BACKUP_SET` | yes, `restore.sh` only | | Path to the one backup set directory to restore from |

## Running it locally, via `wslc`

`selftest.sh` and `restore-selftest.sh` are the real proof and run under
`docker` on the self-hosted CI runner, the same split as
`../migrations/selftest.sh`: not runnable on Nasir's Windows machine, which
has no `docker`, only `wslc`. One backup run by hand, against the dev
stack's own throwaway data, after `riftal-mysql` is up:

```sh
export MSYS_NO_PATHCONV=1
INFRA=C:/Users/nasir/riftal-games/riftal-infra
set -a; . "$INFRA/images/.env"; set +a

wslc run --rm --network riftal-dev \
  -v "$INFRA/deploy:/deploy:ro" \
  -v riftal-backups:/backups \
  -v riftal-world:/worlds/riftal-world:ro \
  -v riftal-world-b:/worlds/riftal-world-b:ro \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE=riftal_dev -e BACKUP_RETENTION="${BACKUP_RETENTION:-10}" \
  mysql:8 bash /deploy/backup.sh
```

And the matching restore, naming one backup set directory that run produced
(list `riftal-backups` to find one, or read the loop's own log). Note the
world volumes are mounted read-write here, unlike the backup run above,
because restoring writes into them:

```sh
wslc run --rm --network riftal-dev \
  -v "$INFRA/deploy:/deploy:ro" \
  -v riftal-backups:/backups:ro \
  -v riftal-world:/worlds/riftal-world \
  -v riftal-world-b:/worlds/riftal-world-b \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE=riftal_dev -e BACKUP_SET=/backups/<timestamp> \
  mysql:8 bash /deploy/restore.sh
```

Wrap either in `timeout 120` when running unattended.
