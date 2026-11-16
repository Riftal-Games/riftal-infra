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

## The capture fence

A flow that commits a removal in MySQL and only then hands the item to a
player would be copied by a restore if the dump fell before the commit and an
instance's held tick after the delivery. So the run raises the one row of
`capture_fence` before `mysqldump` and lowers it only after the last volume is
verified (riftal-pm ADR 027 item 5). While it is raised, every commit-first
procedure answers `capture_fenced` and the item waits.

The order of a run: take the lock, raise the fence under the run's request id
for `CAPTURE_FENCE_MAX_SECONDS`, dump, write the capture request, wait for the
acks, tar and verify each volume, check that the run's own lease is still live,
delete the request, lower the fence, write the manifest. The check is what
makes a set safe: a lease that lapsed mid-run fails the run with `capture
fence lapsed` and no set is produced. The manifest gains `capture_fence:
<request id>`.

- A raise answering `busy`, or failing, fails the run before the dump. `busy`
  means another run's lease is live.
- The EXIT trap deletes the request and lowers the fence by id on every exit.
  A lower that fails is logged and the lease ends the fence. After a killed
  run, commit-first flows stay refused for the rest of the lease, up to
  `CAPTURE_FENCE_MAX_SECONDS`.
- `backup.sh` refuses to start unless `CAPTURE_FENCE_MAX_SECONDS` is above
  `CAPTURE_HOLD_MAX_SECONDS` and at most 3600, `capture_fence_raise`'s bound.
- The fence is written through `capture_fence_raise` and `capture_fence_lower`,
  which riftal-game's migration 0027 creates and its `grants.sql` grants to
  the dump login's role. The `dump-login` compose service applies no grants
  file (`../images/compose.yaml`), so on a stack where only it has run, the
  role lacks `EXECUTE` on `capture_fence_raise` and every run fails at the
  raise, before the dump. That fails safe: no set is written and no fence is
  left raised. Apply the migrations and grants (`../migrations/README.md`)
  before the first scheduled run.
- `deploy/fence-fixture.sql` is a copy of the table and the two procedures that
  the self-tests load into their throwaway databases.

## The held capture

`backup.sh` never tars a running instance live (riftal-pm ADR 015). After the
dump it writes `/capture/request` on the `riftal-capture` volume, holding a
request id and a lease deadline of `CAPTURE_HOLD_MAX_SECONDS`, and
`RiftalCapture` on each instance holds one tick for it: it saves, stages its
`players/` under `.capture/<request id>/` on the instance's own volume and
writes `.capture/<request id>/ack` there. Per volume under `WORLDS_DIR`, the
run tests `server.lock` with `flock -xn` on the read-only mount:

- **Held.** The instance is running and must ack within
  `CAPTURE_ACK_TIMEOUT_SECONDS`. One that does not, because it lacks the
  plugin, is hung, or only left an ack for another request id, fails the run
  naming the volume. The volume's tar leaves out `players/` and `.capture/` and
  stores the staged copy as `players/`. The manifest says
  `capture_mode.<volume>: held <request id>`.
- **Free, or `server.lock` absent.** The instance is down. The tar is the volume
  as it lies and the manifest says `capture_mode.<volume>: stopped`.

Each volume is listed by name, size and mtime before and after its tar. A
listing that differs, or a `tar` exit that counts as a change, discards the tar
and tars the volume once more under the same request. A second change fails the
run and writes no set. The log names every entry in one listing and not the
other, and each volume's `tar` exit status.

Both modes need util-linux `flock`, which `mysql:8` does not carry, so the
`backup` service runs in the image built from `../images/backup`
(`ubuntu:24.04` plus the MySQL client), tagged `riftal-backup`.

`selftest.sh` builds that image and runs `backup.sh` in it. Its holder
container takes a shared `flock` on `server.lock` as core does, and a shell
responder plays `RiftalCapture`. It covers a held volume with and without an
ack, an ack for another request id or with another id inside it, a free lock and
an absent one. A `tar` shim first on `PATH` runs the image's own `tar`, then
waits until the test has made one write to the volume, then exits with a chosen
status. That fixes both the write and the exit status, so no timing is left to
chance: item-free writes on a held volume, a level file written on a held
volume, `server.log` and `plugin_data/` writes on a down volume, exit 2 and a
signal. Each of five mutants of `backup.sh` must turn its case red.

## The dump login

`backup.sh` dumps as the login `backup`, whose password is
`RIFTAL_DB_PASSWORD_BACKUP`. `../migrations/run-migrations.sh` creates it on
any run with that variable set, grants it `riftal_role_backup`, and rotates it
when the variable changes. On the compose stack the `dump-login` service is
that run, and the `backup` service starts only after it exits 0
(`../images/README.md`). The role holds `SELECT`, `SHOW VIEW` and `TRIGGER`
on the schema and the global `SHOW_ROUTINE`. The last two matter: without
them `mysqldump` still exits 0 and silently leaves every trigger or stored
procedure out of the set. `../migrations/selftest.sh` proves `backup` is
denied `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`, `ALTER TABLE`,
`DROP TABLE`, `LOCK TABLES`, `CREATE EVENT`, `CREATE USER` and `GRANT`.
The login writes no table directly. Apart from the password and locks below,
it has two exceptions. The first is the capture fence, which it changes only
through `EXECUTE` on `capture_fence_raise` and `capture_fence_lower`; the
procedures run as their definer, so the login holds no `UPDATE` on the table. The second
is trigger DDL. MySQL ties seeing a trigger to creating and dropping one, so
`TRIGGER` lets `backup` drop any existing trigger in the schema, whatever the
binlog setting, and with it whatever that trigger enforces. With the binlog
on, as `binlog-check.sh` requires, MySQL refuses only `CREATE TRIGGER` to a
login without `SUPER`. With the binlog off, or
`log_bin_trust_function_creators` set, `backup` can create triggers too, and
a `SIGNAL` trigger can block writers. `../migrations/selftest.sh` pins each
of these: the refused create, the accepted drop, and the create once the
guard is lifted.
`backup` can change its own password and default role and take named locks
(`GET_LOCK`), including the runner's `riftal_schema_migrations`, because
those need no privilege. It can take shared row locks
(`SELECT ... FOR SHARE`), because they come with the `SELECT` the dump needs.
Their effect is on availability only: backups or migrations stop, or writers
wait, until the login is reprovisioned or its session ends.
`restore.sh` runs as the admin account, because it drops and recreates
the schema and recreates each procedure under its original `DEFINER`.

## Retention

`BACKUP_RETENTION` (default 10, see `images/.env.example`) is how many backup
sets survive. After a successful run, `backup.sh` lists `BACKUP_ROOT`'s
subdirectories, oldest first, and removes whichever are beyond that count.
Pruning only happens after a run succeeds, so a failed run never deletes a
good backup to make room for the one it never produced.

That listing excludes any `*.partial`, `.lock`, and `.lock.discard.*` entry
outright, so none of the three is ever counted as a backup or pruned as one.
Each is explained where it is produced: Stale `.partial` sweep, Stale lock
sweep, and Orphaned lock-discard sweep, below.

## Stale `.partial` sweep

A `.partial` directory is left behind by a run killed non-gracefully (OOM, a
SIGKILL past the grace period, a host crash) before it could rename itself
into a completed backup set. Retention deliberately never prunes one, since
a fresh `.partial` might be a run still in progress, but nothing else used
to clean these up either, so they could accumulate silently
(riftal-infra#151).

Before each run does anything else, it looks for any `.partial` older than
`PARTIAL_MAX_AGE_MINUTES` (default 360, six hours, see `images/.env.example`)
and removes it, logging the directory it removed and why. A run that old is
never coming back to finish, and a `.partial` younger than the threshold is
always left alone, so a backup genuinely still in progress is never at risk.

## Stale lock sweep

The `$BACKUP_ROOT/.lock` directory (see Concurrency, below) is released only
by the script's own `EXIT` trap, which a hard kill (OOM, a SIGKILL past the
grace period, a host crash) bypasses entirely, unlike `flock`, which the
kernel releases automatically on process death with no equivalent here.
Without a sweep, a lock stranded that way would fail every subsequent run
forever, until an operator manually removes it.

When the claim fails because the lock already exists, `backup.sh` checks its
age. One older than `LOCK_MAX_AGE_MINUTES` (default 90, see
`images/.env.example`) cannot belong to a run still working: a real run's own
mysqldump-plus-tar duration is nowhere near that, so it is presumed abandoned
and cleared. A lock younger than the threshold is left alone and the run
fails fast exactly as before.

Clearing it is a rename, not a delete: the stale `$LOCK_DIR` is moved aside to
a name unique to this run, since `rename(2)` needs its source to still exist,
and only one of two runs racing to steal the same abandoned lock can ever
find it there. The loser's rename fails outright instead of silently
capturing whatever the winner puts at `$LOCK_DIR` next (riftal-infra#175).
Because a rename does not touch what it moves, the run that wins re-checks
its own captured copy's age before trusting it: a directory recreated by
whoever won a concurrent race for the same lock fails that same staleness
test, and the loser hands it straight back and fails fast rather than
deleting a lock someone else legitimately holds. Only once the captured copy
is confirmed still the original abandoned one does the run discard it and
retry the claim. If that retry still fails, something else is genuinely
wrong and the run fails normally rather than retrying further.

A run whose lock is swept while it is still genuinely working, not crashed,
is possible once a lock can be swept at all: `LOCK_MAX_AGE_MINUTES` set too
tight for a slower run at a larger scale, for instance. To keep that from
turning into a second, worse failure, every acquisition stamps a unique
owner token (a PID and this run's own timestamp) inside `$LOCK_DIR/owner`,
and a run only ever removes the lock at exit if that token is still the one
it wrote. A run that finds someone else's token there logs that it no longer
owns the lock and leaves it alone, instead of deleting whoever swept and
reacquired it out from under them.

## Orphaned lock-discard sweep

`$LOCK_DIR.discard.*` is the rename target a stale-lock steal (Stale lock
sweep, above) moves the abandoned lock to, on its way to deciding whether
that lock is genuinely abandoned or was recreated by a competing sweeper.
Either way the steal itself resolves the directory before moving on: it is
renamed back if it turns out to hold someone else's live lock, or removed
with `rm -rf` once the steal is confirmed clean. The same name is where a
claim builds its lock before renaming it into place (see Concurrency,
below). A run killed before renaming or removing the directory leaves it
behind, orphaned (riftal-infra#175, riftal-infra#183).

Right after a run acquires the lock, after the `.partial` sweep above, it
sweeps every `$LOCK_DIR.discard.*` directory it finds, logging each one it
removes. No age filter applies here, unlike the `.partial` and stale-lock
sweeps above: `acquire_lock` only ever returns, as it just has for this run,
once every discard directory it itself created has already been renamed away
or removed, so this run's own discard directory is never still here to sweep.
A discard directory left by a different, still-running process is safe to
sweep too. If that process is stealing a stale lock, its staleness check on
its now-missing discard directory finds nothing, so it takes the existing
"hand it back" branch. If it is claiming the lock, its stamp or rename finds
nothing to act on, so the claim fails. Either way it fails with the same
"another run already holds the lock" error every other contention path
already produces.

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

The dump carries no MySQL roles or logins, so a restore onto a fresh server
leaves every plugin login missing. Run `../migrations/run-migrations.sh`
after every restore, with `GRANTS_FILE` and each `RIFTAL_DB_PASSWORD_<NAME>`
set: it reapplies no recorded migration and rebuilds the roles and logins
(`../migrations/README.md`, Provisioning logins).

Before any of that, `restore.sh` lists every world tar in the set with
`tar -tzf` and fails loudly if any one of them does not extract cleanly. This
runs before the database is touched and before any target directory is
cleared, so a corrupt tar for one world in a multi-world set aborts the whole
restore instead of being found only after earlier worlds have already been
cleared and left neither restored nor in their pre-restore state.

After the tars list cleanly and still before anything is dropped or cleared,
`restore.sh` refuses while any other session is connected to the database
server, whatever that session's default database, because a running instance
would keep writing through the restore. Stop every instance and the `backup`
service first. There is no override. The check reads
`performance_schema.processlist` and refuses rather than guesses when it
cannot see every session:

| Refusal | Meaning |
|---|---|
| `refused: <n> other session(s) are connected to <host>:<port>; close every other connection, instances first` | Another connection is open. Close it and run again |
| `refused: <user> lacks PROCESS, directly or through an active role, so it cannot see every session` | Without `PROCESS` the account sees only its own threads, so a count of 0 proves nothing. Use the admin account |
| `refused: the processlist does not show this session, so it cannot see the others; is performance_schema off?` | The count is not trusted until it includes the script's own connection |
| `refused: the manifest has no valid capture_mode line for every world volume, so the volumes may not share one tick; set ALLOW_UNCAPTURED_SET=1 to restore it anyway` | See below. A missing `manifest.txt` is the same refusal |
| `refused: the manifest has no capture_fence line, ...` | See below |
| `refused: the server.lock of volume <name> is held, so its instance is running; stop it first` | An instance on this host has that volume mounted and running. Stop it. There is no override |
| `cannot give the server.lock of volume <name> the owner of <dir>, so core could not open it; run this as root` | Raised after the database is rebuilt. The restore was not run as root, so it could not give `server.lock` the directory's owner. Run it again as root; it is not reported complete |
| `refused: flock is not installed, so a running instance cannot be detected; run this in the backup image` | `mysql:8` has no `flock`. Run `restore.sh` in the `riftal-backup` image |
| `refused: volume(s) <names> not mounted under <WORLDS_DIR>, so the database would be rebuilt without its level; add a -v line for each` | The run has no mount at `WORLDS_DIR/<name>` for a volume in the set. Raised right after the tars list, before the database is read or any `server.lock` is made. Without it the tar would extract into the container's own filesystem and be lost while the database rolled back. Add the `-v` line |
| `refused: mountpoint is not installed, ...` | Run `restore.sh` in the `riftal-backup` image |

The check reads the moment it runs. A session opened afterwards is not seen.

`restore.sh` runs in the `riftal-backup` image (`../images/backup`), because it
tests each target volume's `server.lock` with `flock`. The processlist sees the
session of an instance on any host, but not an instance that has not connected
yet. The lock sees an instance on this host even before it connects, and an
instance on another host cannot mount these volumes, so both refusals stand.
In two passes, all before the database is touched, it takes an exclusive
`flock -xn` on the `server.lock` of every target volume: the first pass tries each file that exists and writes nothing if one is
held, the second creates and locks the file of each volume that has none. The
locks are held until the script exits. A core start meanwhile opens no world:
it blocks in its own `flock`, or fails to open a file created as root. Each
volume's `server.lock` is left out of the clearing and out of the extract, since
replacing the file would swap the locked inode for one nothing holds. After the
extract the file is given the owner and group of the volume directory, as
extracted, because core opens it for writing as its own user. `chown` keeps the
inode, so the lock still guards it. An instance that was down leaves a free
`server.lock` behind after a crash, which does not refuse. A restore that fails
after the second pass, for example on the database load, can leave a root-owned
`server.lock` in each volume it created one in and the extract has not reached.
Run the restore again as root: the extract gives each the directory's owner.

Before the tars are listed, `restore.sh` refuses a set whose `manifest.txt`
lacks a `capture_mode.<volume>: held <request id>` or
`capture_mode.<volume>: stopped` line for any world tar's volume. That is every
set written before capture modes, and such a set was not taken at one tick.
`ALLOW_UNCAPTURED_SET=1` restores it anyway and prints a warning; reserve it
for a disaster with nothing better.

`restore.sh` also refuses a set whose `manifest.txt` has no `capture_fence:`
line, before it touches anything: `refused: the manifest has no capture_fence
line, so this set may hold an item twice; set ALLOW_UNFENCED_SET=1 to restore it
anyway`. Such a set predates the capture fence, so its dump can hold a
commit-first delivery that a held volume also holds. `ALLOW_UNFENCED_SET=1`
accepts that copy and restores the set as is, without lowering the fence.

After it loads `mysql.sql` from a set that has the line, `restore.sh` runs
`UPDATE capture_fence SET request_id = NULL, raised_until = NULL WHERE id = 1`
as the admin account. The dump holds the row raised by the run that took the
set, and until its lease ended every commit-first flow would answer
`capture_fenced` and the next `backup.sh` run would answer `busy`.

Wiping between MVPs is its own runbook, [`WIPE.md`](WIPE.md). It drops and
recreates the database and clears the levels, `players/` and `plugin_data/`
on every instance volume, and its rollback is this restore with the backup
set taken just before the wipe. Every wipe of alpha or production data is Nasir's.

Replacing one zone's level on a volume that already holds it is
[`LEVEL-REPLACE.md`](LEVEL-REPLACE.md). Its first rollback is a rename of the old folder
back, which touches nothing else; this restore is its fallback and discards the database
and every volume with it. Every swap of alpha or production data is Nasir's.

## Binary log retention

The shared database keeps its binary log for **30 days**
(`binlog_expire_logs_seconds = 2592000`), with the log on, in `ROW` format with
`FULL` row images, and purged automatically once a file is older than that.
The riftal-pm workspace's ADR 005 names the binlog as the only per-change
history of a balance, and hands its retention to this repo (riftal-infra#268).

These are `mysql:8`'s own defaults, and nothing in this repo sets them.
Verified 2026-09-29 on `mysql:8` at repo digest
`mysql@sha256:0744ee5ef89ce6ccfa13de3e579fe6b9e27f93dd70da9c06d2c908b1b193fb8d`,
MySQL 8.4.11, a throwaway container started with no options:

```
log_bin=1 binlog_format=ROW binlog_row_image=FULL
binlog_expire_logs_seconds=2592000 binlog_expire_logs_auto_purge=1
```

`mysql:8` is a floating tag, so the default can move under us on a pull.
`binlog-check.sh` reads those five values from a running server and fails,
naming the setting, if any differs. Run it against a database before relying
on its binlog as history, and against the production database definition
when one exists, as part of bringing it up. `binlog-selftest.sh` runs it in CI
against a default `mysql:8`, which must pass, and against one started with a
one-day retention, which must fail.

What this means for backup and restore:

- **Binlogs are kept, but not backed up.** They live in the MySQL data
  directory (`/var/lib/mysql/binlog.*`), so they survive a container
  replacement on the `riftal-mysql` volume. A backup set holds only
  `mysql.sql` and the world tars; losing the MySQL volume loses every binlog,
  whatever the backups hold.
- **No point-in-time recovery.** `restore.sh` rebuilds the database to the
  moment of one backup set and replays nothing from the binlog, and the dump
  records no binlog position to replay from. Changes after that set are gone
  from the database. On a restore into the same server they stay readable in
  the binlog for an investigation, as long as the files are younger than 30
  days. A restore onto a fresh server starts with no binlog history at all.
- **The binlog outlasts every backup set.** At the default schedule
  (`BACKUP_RETENTION` 10, `BACKUP_INTERVAL_SECONDS` 21600) the oldest set is
  2.5 days old, well inside 30 days. Raising either so that
  `BACKUP_RETENTION * BACKUP_INTERVAL_SECONDS` passes 30 days leaves the
  oldest sets older than any change history the binlog still holds.
- **The binlog costs disk on the MySQL volume.** 30 days of row images for
  every write is sized by write volume, not by database size, so watch the
  volume's free space as the alpha grows.

To check the dev stack, with `riftal-mysql` up and the variables set as in
Running it locally, via `wslc`, below:

```sh
wslc run --rm --network riftal-dev \
  -v "$INFRA/deploy:/deploy:ro" \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  mysql:8 bash /deploy/binlog-check.sh
```

## Custody alert check

`custody-alert-check.sh <log> [<log> ...]` reads one instance's logs, one file
per process lifetime, oldest first, and alerts when a RiftalCustody
`emergency` repeats (the riftal-pm workspace's ADR 017 item 4). It reads files
only and stops, restarts or parks nothing; acting on an alert is a separate,
later decision. It prints one `CUSTODY ALERT:` line per finding and exits 1
when two consecutive logs each hold an instance-wide custody stop, when one
player is refused twice or more anywhere in the logs given (names compared
case-insensitively), or when an `EMERGENCY` line mentioning RiftalCustody
matches no known shape, so a reworded custody line alerts rather than going
quiet. Otherwise it prints one `CUSTODY OK:` line and exits 0. Exit 2 is a
usage error, an unreadable log, a log holding more than one boot, a log after
the first holding no boot, or a first log holding no boot but a custody
`EMERGENCY` line, never a pass.

An instance's `server.log` is not one lifetime per file. PocketMine appends to
it across restarts and archives it into `log_archive/` by size, even mid-run
(pmmp-core `src/utils/MainLoggerThread.php:95`, `:137-139`), so one file holds
every boot since the last archive, a restart loop in it would read as one
log's stops, and one lifetime can start in an archive and end in `server.log`.
The check counts each boot's `Loading server configuration` line (pmmp-core
`src/Server.php:813`, logged once per process and never translated) and exits 2
when a file holds more than one. Concatenate a copy of every
`log_archive/*.log`, oldest first, ahead of `server.log`, split that at the
boot line, and pass the pieces in order. Archive names carry their timestamp,
so the glob sorts them oldest first:

```bash
cat log_archive/*.log server.log \
  | awk '/\/INFO\]: Loading server configuration/ { n++ } { print > sprintf("life-%03d.log", n) }'
deploy/custody-alert-check.sh life-*.log
```

Splitting each file on its own would leave the tail of an archived lifetime as
a piece with no boot line, and the empty head piece before it would hide two
consecutive stops, so every piece after the first must hold a boot line or the
check exits 2. `life-000.log`, when written, holds what precedes the oldest
boot line: performance warnings, or the end of a lifetime whose start is no
longer kept. It passes when it holds no custody line, since it then changes no
finding, and exits 2 when it holds one, since that lifetime's start is
missing. A boot's performance warnings come just before its boot line and so
land in the piece before; they carry no custody line. `../images/loads-check.sh`
already fails one boot on any `EMERGENCY` line; this is the view across boots.
A log left out of the middle of the list makes two stops look consecutive or
hides one between them, so give it every lifetime in order.
`custody-alert-check-selftest.sh` proves each rule in CI against fixture logs.

## Grants REVOKE check

`grants-revoke-check.sh <new-grants.sql> <release-tag> [<tag>=<grants.sql> ...]`
refuses a `grants.sql` whose REVOKE statements are new against an image tag
that can still run (riftal-infra#944, riftal-pm ADR 008 item 3).
`../migrations/run-migrations.sh` applies the file on every run, and
`/deploy-release` stage 1 runs the migrations before stage 2 rolls instances
one at a time. A REVOKE applied while an instance still runs the previous tag
takes a privilege that instance still needs: every statement that uses it
fails with ERROR 1142 or 1143. The check reads files and lists containers. It
stops, starts and removes nothing.

The check belongs in `/deploy-release` stage 1, before the migrations run. The
skill does not run it yet; until the skill's wiring lands, whoever runs stage 1
runs the check by hand and does not start the migrations on a refusal.

Each `<tag>=<file>` names the `grants.sql` that tag's plugins were built from.
The operator supplies it from the riftal-game commit the tag was built at. A tag
in use with no mapping is a refusal, never a pass.

A release image (see Release image below) carries the sha256 of that file in the
label `org.riftal.grants-sha256`, and the commit in `org.riftal.game-commit`. The
check reads the sha256 with `<runtime> image inspect` for every tag in use other
than `<release-tag>`. The label holds the hash and not the file, and the image
holds no `grants.sql`, so a labelled tag still needs its `<tag>=<file>`: the
check cannot derive the file locally, and fetching it from a network or a
registry is out of scope. What the label adds is that a supplied file whose
sha256 differs from it exits 2, so a file from another commit exits 2 even when
it is valid. A tag whose image has no label, or cannot be inspected on the
runtime, is checked against the supplied file alone. A label that is not 64
lowercase hex digits exits 2. Baking `grants.sql` into the image is tracked in
riftal-infra#1272.

`instances/<id>/image` records the tag an instance runs: one line,
`<INSTANCE_IMAGE>:<tag>`, with an optional final LF. The tag matches
`[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}` and is not `latest`. Each immediate
subdirectory of `INSTANCES_DIR` is one instance definition and must hold that
file, a regular readable one, links followed. A top-level entry that is not a
directory, other than `.gitkeep`, is an error, because a definition is a
directory. The scan reads the checkout it runs from, so run it from riftal-infra
`main` at the release commit. A deploy or a rollback of one instance is a
one-line change to its file.

`instances/alpha/` is the closed alpha's definition: its `image` is the release
tag the alpha runs, and its `instance.env` is the only source of the zone list,
the level name, the roster and the database host and schema, with no secret in
it. `.gitignore` ignores `*.env` and negates `instances/*/instance.env`, so a
definition's `instance.env` is tracked.

A tag is in use when any of these names it:

- a running container;
- a stopped container, listed by `ps -a`;
- an instance definition's `image` file;
- any other file under `INSTANCES_DIR`, links followed, with the line it
  appears on.

Every tag in use other than `<release-tag>` is checked. A REVOKE in the new file
that the older tag's file does not also carry is new against that tag. A REVOKE
the new file drops is not a hazard. Statements compare as a set of texts with
whitespace collapsed, so the check does not see a REVOKE the older file later
undoes with a GRANT of the same privilege: it counts as carried.

| Exit | Output |
|---|---|
| 0 | One `GRANTS REVOKE OK:` line: the REVOKE count, the file, the older tags checked, the tags in use, the runtime, the instance definitions read |
| 1 | One `GRANTS REVOKE REFUSED:` line per new REVOKE and tag, each naming the container or definition that holds the tag |
| 2 | Usage, an unreadable file or instance definition, a definition with no valid `image` file, a top-level entry that is not a directory, a failed definition scan, a failed runtime, an image whose tag cannot be read, a tag in use with no `grants.sql`, a supplied file whose sha256 differs from the tag's label, a label that is not a sha256, or a file outside the dialect below |

Exit 2 is never a pass. The reader accepts the one dialect riftal-game's
`lib/resources/sql/grants.sql` is written in, and exits 2 naming the file and
line on anything else: no `#` or `/* */` comment, quote, backtick, backslash,
`DROP` or client command, and every statement begins with `CREATE ROLE`,
`GRANT` or `REVOKE`. A `--` comment ends at the line end, and no byte may be
other than printable ASCII, tab, CR or LF.

Environment:

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `INSTANCE_IMAGE` | yes | | The image name without its tag, exactly as the runtime reports it |
| `CONTAINER_RUNTIME` | no | `docker` | The runtime command, which may carry arguments |
| `INSTANCES_DIR` | no | `instances/` beside `deploy/` | Where instance definitions are read, whatever the working directory |

What a pass does not cover:

- **One runtime per run.** Containers come from the single `CONTAINER_RUNTIME`
  given, on the one machine it reaches. Run the check once per runtime and per
  machine that runs instances, each with its own `INSTANCE_IMAGE` and its own
  result. A pass on one machine says nothing about another.
- **One reference per run.** `INSTANCE_IMAGE` must be the exact reference the
  runtime reports, registry prefix included. A container under any other
  reference is skipped as not ours, so a mistyped value passes with the
  containers it should have caught unseen. Take it from the runtime's own
  output, for example `docker ps -a --format '{{.Image}}'`, and never from the
  compose file.
- **Mutable references.** A container or definition naming the image with no
  tag, by digest, as `latest`, or known only by id exits 2, because its tag
  cannot be read.

Example, with one instance still on `v1` and the release at `v2`:

```sh
INSTANCE_IMAGE=registry.example/riftal/pocketmine-mp \
  deploy/grants-revoke-check.sh new/grants.sql v2 v1=old/grants.sql
```

`grants-revoke-check-selftest.sh` proves each rule in CI against a fake
container runtime that serves labels, and fixture files, and starts no container.

## Release image

`GAME_COMMIT=<sha> GRANTS_SQL=<grants.sql> release-image.sh <phars directory>`,
run from a clean checkout of riftal-infra, builds an image on top of the pinned core
image, `../images/core-image.sha`, which is `ubuntu:24.04` underneath and must
already be on the daemon, since nothing here builds or pulls it. The image adds
ten production phars in `/opt/riftal/plugins`: `RiftalCustody.phar`,
`RiftalAccounts.phar`, `contracts.phar`, `RiftalMines.phar`, `RiftalRanks.phar`,
`RiftalEconomy.phar`, `RiftalGangs.phar`, `RiftalRiots.phar`, `RiftalPlots.phar`
and `RiftalAnvil.phar`, from `../images/release/Dockerfile`, and the script
plugin `RiftalDownstreamLimit.php` from `../images/plugins`. They are
mode 0444 and owned by root, in directories owned by root, so `pocketmine` can
neither rewrite nor replace one. They sit outside `/data` and `/plugins`,
the base's two VOLUMEs, so a mount or a reused volume cannot hide them there or
keep an older tag's copies. `/plugins` in the image holds no phar. The script
uses only the local Docker daemon and pushes nowhere. A registry is a separate
decision, because a paid one costs money.

The image's command is `/opt/riftal/start-release.sh` (`../images/release/`),
not core's `start-pocketmine`, which passes `--plugins=/plugins`. It builds the
roster from `/opt/riftal/plugins` into a `mktemp -d` copy and passes PocketMine that
copy alone, so a mount or a reused volume on `/plugins` is never read. RiftalCustody,
RiftalAccounts, contracts and `RiftalDownstreamLimit.php` load everywhere, and a missing one stops the boot. `RIFTAL_PLUGINS` adds
`RiftalMines`, `RiftalRanks`, `RiftalEconomy`, `RiftalGangs`, `RiftalRiots`,
`RiftalPlots` and `RiftalAnvil`, space or comma separated, and a name outside
those seven stops the boot. The instance sets `RIFTAL_DB_HOST`
and `RIFTAL_DB_SCHEMA`, which the script writes into each loaded plugin's
`/data/plugin_data/<Plugin>/config.yml` on every boot, from the configs the
dev stack uses for Accounts, Mines, Ranks and Economy and, for Gangs, Riots and
Plots, from riftal-game's shipped configs at `7159d24`
(`../images/release/config/`), which the dev stack does not run. Anvil has no
config and no login. The password of Accounts and of each added plugin with a
login comes from
`RIFTAL_DB_PASSWORD_<ACCOUNTS|MINES|RANKS|ECONOMY|GANGS|RIOTS|PLOTS>`, and a
missing one stops the
boot before PocketMine starts. Gangs, Riots and Plots read the designer's
`world_index.json` from their data folders; the instance mounts it read-only at
`/etc/riftal/world_index.json`, the path the dev stack uses, and the script
copies it to each of the three on every boot. A roster naming one of them with
no readable, non-empty file there stops the boot. Ranks, Mines and Economy read
the same index and this script does not deliver it to them. A `--plugins` or `--data` in `POCKETMINE_ARGS` is
refused. The script prints each roster phar's sha256 as a `roster` line, which
is what the label can be compared with.

`RiftalDownstreamLimit.php` turns RakLib's per-address packet limit off on
every RakLib interface, because behind the proxy all players share the proxy's
address. It acts only when the instance's service definition passes
`--riftal-downstream=on` (or a `riftal-downstream=on` line in
`server.properties`) and `xbox-auth` is off; otherwise it makes no call and
logs why. No instance sets the option today, and a downstream must publish no
port (spec 016). `images/plugins/downstream-limit/selftest.sh` holds it.

`GAME_COMMIT` is the full lowercase 40-character riftal-game sha the phars and
`GRANTS_SQL` were built from, and `GRANTS_SQL` is that commit's `grants.sql`.
The script refuses a `GAME_COMMIT` that is unset or malformed and a `GRANTS_SQL`
that is unset, missing, a directory or empty, and records them in the labels
`org.riftal.game-commit` and `org.riftal.grants-sha256`. It is the operator's
word that they match the phars, since nothing here builds
riftal-game. The file itself is not put in the image.

The phars come from riftal-game's build. The recipes are in
`../images/README.md` (Custody, Accounts, contracts) and in
`../images/plugins/instance-only/README.md` (Mines, Ranks, Economy). The script
refuses a missing or empty one by name, and carries no dev-only plugin.

Gangs, Riots, Plots and Anvil use the RiftalCustody recipe in
`../images/README.md` with `gangs riots plots anvil contracts` added to its
`git archive` paths, so `lib` and `contracts` sit beside them for their path
repositories. `packages.sh phar` then builds a phar named after each folder, and
each is copied to the name the script requires:

```sh
cp "$OUT/gangs.phar" RiftalGangs.phar
cp "$OUT/riots.phar" RiftalRiots.phar
cp "$OUT/plots.phar" RiftalPlots.phar
cp "$OUT/anvil.phar" RiftalAnvil.phar
```

`RIFTAL_PLUGINS` offers these four. Their configs in `../images/release/config/`
are copies of riftal-game's shipped files, so a riftal-game config change
reaches an image only when a riftal-infra commit copies it; a copy older than the
phars can leave a key the plugin requires missing, and the plugin then fails to
enable.

The tag is
`<UTC date>-core<7 of the pinned pmmp-core sha>-game<7 of GAME_COMMIT>-infra<7 of the riftal-infra commit>`,
for example `2026-11-10-core971d10b-gamefcf772f-infra4f183d3`, under the name
`riftal/pocketmine-mp` (`RELEASE_IMAGE` overrides it, `RELEASE_DATE` the date).
There is no `latest`. An existing tag is refused rather than rebuilt. The tag
follows every input that changes the image, so a riftal-game-only release on
the same day gets its own tag and two daemons cannot build one tag over
different phars.

The riftal-infra commit is the `HEAD` of the checkout holding the script, the
same checkout the Dockerfile and the core pin are read from. The build is
refused when that checkout is not the top of a git work tree of its own with a
commit (a subdirectory of another repository would name that repository's
commit), when git cannot report its status, or when a tracked file differs from
`HEAD`, since the commit would not describe what was built. Untracked files are
not inputs and do not refuse it. Build from a committed, clean checkout of the
commit being released.

The image records what it holds in five labels: `org.riftal.core-image`,
`org.riftal.phars` (each phar's sha256), `org.riftal.game-commit`,
`org.riftal.infra-commit` and `org.riftal.grants-sha256`.
Recording the tag in `../instances/<id>/image` is a deploy, and an instance
started from the image runs the image's own phars.

`release-image-selftest.sh` builds one under a `riftal_smoke_` name and checks
the tag and that it changes with the riftal-game and riftal-infra commits, the
refusal of each phar when empty, and of a checkout with no `.git`, with no
commit, inside a `.git` directory, in a subdirectory of a repository, with a
status git cannot report, with a modified tracked file or with a staged new
file, the absence of a `latest` tag and the refusal of an existing tag. It runs
a committed copy of the release files in a temporary repository, from another
repository's directory, so the commit it checks is the one read from beside the
script. In the image it checks each phar byte for byte,
that `/opt/riftal/plugins` holds exactly the ten, that they are owned by
root and mode 444, that their directories are root-owned and mode 755, that
`pocketmine` can write none of them, that `/plugins` holds no phar, the Ubuntu
24.04 release file, the `pocketmine` user and the pinned core revision label. It
refuses a malformed `GAME_COMMIT` and a `GRANTS_SQL` that is not a non-empty
file, checks `org.riftal.game-commit`, `org.riftal.infra-commit` and
`org.riftal.grants-sha256` against the inputs and that the image holds no
`grants.sql`. It needs the pinned core image on the daemon.

`release-start-selftest.sh` builds two tags over stub plugins, ten of them as in
`REQUIRED_PHARS`, that differ in version, then boots tag N, N+1 and N on one named `/data` volume and one reused
`/plugins` volume that holds stale copies. Each boot must report the sha256s its
own image's `org.riftal.phars` label names and enable exactly its roster at its
tag's version. It also checks the refusals above, the rendered configs, the
index delivered to Gangs, Riots and Plots, and that the server's user cannot add
a file to `/opt/riftal/plugins`.

## Environment

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `MYSQL_HOST` | yes | | Database host, `mysql` in this stack |
| `MYSQL_PORT` | no | `3306` | |
| `MYSQL_USER` | no | `backup` for `backup.sh`, `root` for `restore.sh` | |
| `MYSQL_PASSWORD` | yes | | Read via `MYSQL_PWD` internally, same as `../migrations/run-migrations.sh` |
| `MYSQL_DATABASE` | yes | | `riftal_dev` in the local stack |
| `BACKUP_ROOT` | no | `/backups` | Where backup sets land; must be a volume, never the container's own layer |
| `WORLDS_DIR` | no | `/worlds` | Parent of one subdirectory per world volume |
| `BACKUP_RETENTION` | no | `10` | Backup sets kept before pruning |
| `BACKUP_INTERVAL_SECONDS` | no | `21600` | `backup-loop.sh` only |
| `PARTIAL_MAX_AGE_MINUTES` | no | `360` | Age past which a leftover `.partial` is swept |
| `LOCK_MAX_AGE_MINUTES` | no | `90` | Age past which a held `.lock` is presumed abandoned and swept |
| `CAPTURE_FENCE_MAX_SECONDS` | no | `1800` | The capture fence's lease, from before the dump until every volume is verified. Must be above `CAPTURE_HOLD_MAX_SECONDS` and at most `3600`, or the run refuses to start |
| `CAPTURE_DIR` | no | `/capture` | Where the capture request is written: the `riftal-capture` volume, read-write here and read-only in every instance |
| `CAPTURE_ACK_TIMEOUT_SECONDS` | no | `60` | How long a held volume has to ack before the run fails |
| `CAPTURE_HOLD_MAX_SECONDS` | no | `900` | The request's lease. Must cover the longest tar, retry included |
| `CAPTURE_TEST_STALL_SECONDS` | no | `0` | Seconds a run stalls between the acks and the tars. Set only by the self-tests and proof runs |
| `CAPTURE_TEST_REQUEST_ID` | no | the run's timestamp | The request id. Set only by the self-tests |
| `FENCE_TEST_STALL_SECONDS` | no | `0` | Seconds a run stalls between its dump and its capture request. Set only by the self-tests |
| `BACKUP_SET` | yes, `restore.sh` only | | Path to the one backup set directory to restore from |
| `ALLOW_UNCAPTURED_SET` | no, `restore.sh` only | | `1` lets `restore.sh` restore a set whose manifest lacks a valid `capture_mode.<volume>:` line for some volume, with a warning. Any other value refuses it |
| `ALLOW_UNFENCED_SET` | no, `restore.sh` only | | `1` lets `restore.sh` restore a set whose manifest has no `capture_fence:` line. Any other value refuses it |
| `WIPE_BACKUP_MAX_AGE_MINUTES` | no, `wipe.sh` only | `60` | Age past which `wipe.sh` refuses its `BACKUP_SET`, read from the manifest's `timestamp:` line. The set is taken with every instance stopped, just before the wipe, so an older one was likely taken while they still wrote |

## Concurrency

`backup.sh` takes an exclusive lock on `$BACKUP_ROOT/.lock` for the duration
of the run, before it touches anything else under `BACKUP_ROOT` (including
the stale-`.partial` sweep above). It builds the lock directory, owner file
included, under its own `$LOCK_DIR.discard.*` name and then renames it to
`.lock`. `rename(2)` is atomic on any POSIX filesystem and refuses to replace
a non-empty directory, so the rename fails while a stamped lock holds
`.lock`. It needs nothing beyond coreutils, unlike `flock`, which is not
installed in every image this script runs in. The owner file is written before the rename,
never after: a lock that existed unstamped, even briefly, could be captured
by a stale-lock sweeper in that gap, leaving both runs failed and an
ownerless lock blocking every run until it ages out (riftal-infra#491). A
second invocation against the same `BACKUP_ROOT`, such as a manual run below
started while the `backup` compose service's scheduled loop is also running,
fails immediately with a loud, logged message rather than waiting or racing,
unless the held lock is stale enough to be swept first (see Stale lock sweep,
above). Two runs against *different* `BACKUP_ROOT` volumes (different
instances, or a manual run pointed at a scratch directory) never contend,
since the lock lives inside `BACKUP_ROOT` itself. If a manual run fails this way, wait for the scheduled
run to finish and try again, or run it against a separate `BACKUP_ROOT`.

## Running it locally, via `wslc`

`selftest.sh` and `restore-selftest.sh` are the real proof and call `docker`
directly, as `../migrations/selftest.sh` does: on the self-hosted CI runner,
and on Nasir's Windows machine under the Docker in the WSL distro that hosts
the CI runners:

```sh
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-26.04 -u runner --exec bash \
  /mnt/c/Users/nasir/riftal-games/riftal-infra/deploy/restore-selftest.sh
```

Each selftest run writes its logs to its own
`mktemp -d` directory and removes it on exit, so concurrent runs on one host
do not clobber each other. One backup run by hand, against the dev
stack's own throwaway data, after `riftal-mysql` is up. It runs in the
`riftal-backup` image, which `mysql:8` cannot stand in for, and mounts
`riftal-capture` read-write, since the run writes its request there. Build the
image once, from `images/backup`, if the stack has not:

```sh
export MSYS_NO_PATHCONV=1
INFRA=C:/Users/nasir/riftal-games/riftal-infra
set -a; . "$INFRA/images/.env"; set +a

timeout 300 wslc build -t riftal-backup "$INFRA/images/backup"

timeout 120 wslc run --rm --network riftal-dev \
  -v "$INFRA/deploy:/deploy:ro" \
  -v riftal-backups:/backups \
  -v riftal-capture:/capture \
  -v riftal-world:/worlds/riftal-world:ro \
  -v riftal-world-b:/worlds/riftal-world-b:ro \
  -e MYSQL_HOST=mysql -e MYSQL_USER=backup -e MYSQL_PASSWORD="$RIFTAL_DB_PASSWORD_BACKUP" \
  -e MYSQL_DATABASE=riftal_dev -e BACKUP_RETENTION="${BACKUP_RETENTION:-10}" \
  riftal-backup bash /deploy/backup.sh
```

An instance running without `RiftalCapture` fails this run after
`CAPTURE_ACK_TIMEOUT_SECONDS`, which is the intended failure.

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
  riftal-backup bash /deploy/restore.sh
```

Wrap either in `timeout 120` when running unattended.
