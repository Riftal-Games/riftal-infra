# Replacing a live zone level

The operator procedure for ADR 009 item 8 (riftal-pm
`docs/decisions/009-zone-levels-are-built-not-committed.md`). Seeding never
replaces a level folder that exists, so a revised recipe changes only what a new
volume gets. Swapping the folder on a volume that already holds the zone is this
procedure.

**This is Nasir's, by hand, every time.** On production it touches real player
data. On the dev stack it touches `riftal-world`, which is not a throwaway volume.
No agent runs the swap, the restore or any step that writes to `riftal-world`,
`riftal-world-b` or any volume that is not a `riftal_smoke_` one. That ban rests on
this document and on riftal-pm's `CLAUDE.md` hard stops (anything reaching real
player data, and the guard). The guard reads command text and does not reliably
catch the commands printed here: they `cd` into the worlds folder on one line,
rename and `chown` relative names on the next, and pass the volume in a variable.
Phrasing around a guard denial is not allowed either. The loop's part is this
document and, once they exist, the selftests.

## What exists, and what does not

The procedure is written against the repository as it stands. Commands in it are
composed from the scripts named, and have not been run end to end, because the
build side below does not exist.

| Piece | State | Where |
|---|---|---|
| Recipe and lock formats, `build_level` driven against a bridge | On `main` | `../designer/levels/README.md`, `../designer/designer/level.py` |
| A committed recipe or lock for any zone | None. `designer/levels/` holds the README only | |
| `build-level` command, the `riftal_smoke_level_<zone>` volume, `level-manifest.json` | Not on `main` | riftal-infra#347 |
| Seed step in the boot chain, `/etc/riftal/levels/<zone>` mount | Not on `main` | riftal-infra#337, #388 |
| Production image that carries levels | Not on `main` | riftal-infra#338 |
| Backup and restore of a whole set | On `main` | `backup.sh`, `restore.sh`, `README.md` |
| Restoring one level out of a set | No tooling. Hand `tar`, below | |
| Recomputing `content_sha256` from an existing folder | No tooling | |

Consequences:

- Until a zone has a committed `designer/levels/<zone>.lock.json` there is nothing
  to verify a replacement against, and the procedure stops at Preconditions.
- `content_sha256` is a hash of block states read through DesignBridge
  (`level.py`, `content_sha256`), not of files. Nothing on `main` recomputes it
  from a folder on a volume. What the steps below can compare today is the value
  the build wrote into `level-manifest.json` against the value in the lock, and
  the copied tree against its source. That proves the folder is the one the lock
  names, if the source is. It does not re-read the blocks.
- The format and location of `level-manifest.json` are riftal-infra#347's. The
  commands below read its `content_sha256` key with `grep` and assume it sits in
  the level folder (riftal-infra#388). Re-read #347's merged format before the
  first run.

## Preconditions

1. The zone has a recipe and lock committed on `main`, and the replacement was
   built from that lock's commit, on the core image the lock records as
   `core_image`. A changed `content_sha256` on the same core image is a build
   failure, not a map change (ADR 009, Consequences).
2. The level folder's name is the zone's name. On the dev stack the instance's
   default level is `mine_a` (`../images/compose.yaml:148`, `--level-name=mine_a`),
   in `/data/worlds/mine_a` on `riftal-world` (`compose.yaml:53`).
3. The old folder is understood to be lost to the live path. Whatever players
   put in it goes with it: a mine resets and holds nothing of theirs, but a plot
   or any zone with containers they filled does not reset (ADR 009, Instance-split
   impact). A player's saved position inside the old level may also land inside
   solid blocks of the new one. Nasir decides per zone whether that is acceptable.
4. The window is announced (`WIPE.md` step 1, `ROLLOUT.md`).

## Steps

Commands are for the dev stack under `wslc`, with the variables set as in
`README.md`, Running it locally. Wrap each in `timeout 120`. Under the Docker in
the WSL distro, run them there with `--exec` (riftal-pm's `CLAUDE.md`, Known setup
gaps).

```sh
export MSYS_NO_PATHCONV=1
INFRA=C:/Users/nasir/riftal-games/riftal-infra
set -a; . "$INFRA/images/.env"; set +a
ZONE=mine_a
VOL=riftal-world
SRC=riftal_smoke_level_$ZONE
```

### 1. Stop everything that writes

Stop every instance with a grace period, never a kill: an abrupt halt can corrupt
a level mid-write. PocketMine traps SIGTERM into the same `shutdown()` as `stop`
(`../.claude/skills/dev-stack/SKILL.md`, Tear down):

```sh
wslc stop -t 60 riftal-instance
wslc logs riftal-instance
wslc inspect riftal-instance
```

Read `Unloading world` and `Stopping other threads` in the log, and exit code 0
in `inspect`, for each instance. Stop the `backup` service too and keep it
stopped until step 6, for the reasons in `WIPE.md` step 2: a scheduled run
between steps 2 and 6 takes a retention slot and can fail on a left-behind
lock. `restore.sh` also refuses while any session is connected to the database,
so the instances have to be down for the rollback anyway.

### 2. Take a backup, and verify it

One `backup.sh` run after the stop, with one read-only mount per instance
volume, as `ROLLOUT.md`, Take the backup:

```sh
wslc run --rm --network riftal-dev \
  -v "$INFRA/deploy:/deploy:ro" \
  -v riftal-backups:/backups \
  -v riftal-world:/worlds/riftal-world:ro \
  -v riftal-world-b:/worlds/riftal-world-b:ro \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE=riftal_dev -e BACKUP_RETENTION="${BACKUP_RETENTION:-10}" \
  mysql:8 bash /deploy/backup.sh
```

The backup counts as verified only when all of these hold. Record the set
directory; it is the rollback.

- Success is the log line `backup <ts>: complete at <set>`, as in `ROLLOUT.md`.
  Retention lines follow it. Without that line no set was left.
- `<set>/manifest.txt` lists the volume that holds the zone, and `<set>/mysql.sql`
  is non-empty. `restore.sh` rebuilds only the volumes the set holds.
- Every tar lists cleanly, which is the check `restore.sh` makes before it touches
  anything (`restore.sh:43-46`):

  ```sh
  wslc run --rm -v riftal-backups:/backups:ro mysql:8 bash -c '
    set -e
    for t in /backups/<ts>/worlds/*.tar.gz; do tar -tzf "$t" >/dev/null && echo "ok $t"; done
    tar -tzf /backups/<ts>/worlds/riftal-world.tar.gz | grep -c "^./worlds/'"$ZONE"'/level.dat$"'
  ```

  Each tar prints `ok`, and the last line prints `1`: the tar holds this zone's
  level (`backup.sh` tars each volume from its root, so entries start with `./`).
- With `backup` stopped until step 6, retention prunes the set `BACKUP_RETENTION - 1`
  intervals after step 6: 9 x 21600 s, 54 hours or about 2.25 days, at the defaults
  (`WIPE.md` step 3). Any other `backup.sh` run into the same `BACKUP_ROOT` brings
  that forward. A window that could outlast that copies the set out of
  `BACKUP_ROOT` before step 6, and where to is Nasir's call (`ROLLOUT.md`).

Nothing stands in for the set: not the build volume, not a copy of the folder
made in step 3. If the backup is not verified, stop here.

### 3. Swap the folder

The source is read-only and never the target. The new folder is copied in under a
temporary name, the live one is renamed aside, and the new one is renamed into
place. No step deletes. Both renames are within `worlds/`, so each is atomic.

Source, by case:

| Case | Source | Source path |
|---|---|---|
| Dev stack | The build volume `riftal_smoke_level_<zone>`, a cache that `build-level` fills (ADR 009 item 6) | `worlds/<zone>/` inside the volume's `/data` tree (riftal-infra#388) |
| Production | The image layer at `/etc/riftal/levels/<zone>` of the image tag being deployed (ADR 009 item 7) | See Production, below |

Dev stack:

```sh
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
wslc run --rm \
  -v "$VOL":/data -v "$SRC":/src:ro \
  -e ZONE="$ZONE" -e STAMP="$STAMP" \
  mysql:8 bash -c '
    set -euo pipefail
    cd /data/worlds
    [ -d "$ZONE" ] || { echo "no live $ZONE: this is a seed, not a replace"; exit 1; }
    [ -d "/src/worlds/$ZONE" ] || { echo "no built $ZONE in the source"; exit 1; }
    [ ! -e ".incoming-$ZONE" ] && [ ! -e ".replaced-$ZONE-$STAMP" ] || { echo "a leftover name exists"; exit 1; }
    cp -a "/src/worlds/$ZONE" ".incoming-$ZONE"
    chown -R 1000:1000 ".incoming-$ZONE"
    mv "$ZONE" ".replaced-$ZONE-$STAMP"
    mv ".incoming-$ZONE" "$ZONE"
    echo "swapped $ZONE, old level at .replaced-$ZONE-$STAMP"'
```

uid 1000 is the `pocketmine` user the seed step copies as (ADR 009 item 5). A
copy owned by root would boot unwritable. The old folder is kept under a dot name
that no zone can take. Do not leave it: see step 7.

### 4. Verify the swap, instance still stopped

Run before any instance starts, since a boot can write to the level.

a. **The tree copied intact.** The two trees list the same files with the same
hashes:

```sh
wslc run --rm -v "$VOL":/data:ro -v "$SRC":/src:ro -e ZONE="$ZONE" mysql:8 bash -c '
  set -euo pipefail
  tree() { (cd "$1" && find . -type f -exec sha256sum {} + | sort -k2); }
  [ "$(tree "/src/worlds/$ZONE")" = "$(tree "/data/worlds/$ZONE")" ] && echo "tree identical"'
```

It must print `tree identical`. The step uses only `find`, `sha256sum` and `sort`,
the tools `wipe-volumes-selftest.sh:72` already runs in `mysql:8`. This is a plain
file comparison. It is not the
manifest's own tree hash, whose algorithm riftal-infra#347 defines.

b. **The seeded `content_sha256` equals the committed lock's.** Read both and
compare them character for character:

```sh
grep '"content_sha256"' "$INFRA/designer/levels/$ZONE.lock.json"
wslc run --rm -v "$VOL":/data:ro -e ZONE="$ZONE" mysql:8 \
  grep content_sha256 "/data/worlds/$ZONE/level-manifest.json"
```

The two 64-hex values must be equal. Different, or the manifest absent, is a
failure. A volume without a manifest was not fully built (ADR 009 item 4,
riftal-infra#347).

The seed step logs the `content_sha256` it seeded (ADR 009 item 5), but only when
it copies an absent folder. A swap is not a seed, so no boot line carries the value
and step 4b is the check.

c. **Production adds the image check**, below.

Any check failing means do not start an instance. Go to Rollback.

### 5. Start

One instance at a time, database first, as `ROLLOUT.md`. Read the log, never the
exit code:

- A line starting `Done (` is present.
- No line matches `/(EMERGENCY|ALERT|CRITICAL|ERROR)]`. PocketMine exits 0 with
  these in the log. `../images/loads-check.sh <log>` checks this bullet and the
  one above, and also fails unless `Enabling RiftalCustody` precedes the first
  `Preparing world`. It does not check the two bullets below.
- `Preparing world "<zone>"` appears, off the volume, and no `Generating spawn
  terrain` line for it (`../.claude/skills/dev-stack/SKILL.md`, the replacement
  check).
- The zone's plugin loads it with no `has no world folder` or `MineWorldLoader`
  WARNING.

This is LOADS. Whether a client can walk the new level is a separate verdict that
only a client run or Nasir gives.

### 6. Start the `backup` service

`backup-loop.sh` runs `backup.sh` at once on start, so the first set after the
swap is taken then.

### 7. Settle the old folder

`.replaced-<zone>-<stamp>` stays on the volume until Nasir removes it. While it
exists it is in every backup tar, `wipe-volumes.sh` and `wipe-check.sh` both
list it as a level, since each sets `dotglob` before reading `worlds/`, and
`wipe-check.sh` fails on it. Nothing in the loop
deletes it. The set from step 2 is the durable record whether or not the folder
is kept.

## Rollback

The failure happens in one of three places, and each has a different way back.

**Before any instance started** (step 3 or 4 failed). Nothing wrote to either
folder. Rename back, which restores the exact bytes and loses nothing:

```sh
wslc run --rm -v "$VOL":/data -e ZONE="$ZONE" -e STAMP="$STAMP" mysql:8 bash -c '
  set -euo pipefail
  cd /data/worlds
  [ -d ".replaced-$ZONE-$STAMP" ] || { echo "no old level to put back"; exit 1; }
  [ ! -e ".rejected-$ZONE-$STAMP" ] || { echo "a leftover name exists"; exit 1; }
  mv "$ZONE" ".rejected-$ZONE-$STAMP"
  mv ".replaced-$ZONE-$STAMP" "$ZONE"'
```

If step 3 died between its two renames there may be no `$ZONE` folder at all, and
the first `mv` fails. Inspect the volume and rename `.replaced-...` back by hand.
Never start an instance with `$ZONE` absent: for a zone that is the default level,
core generates plain terrain there and every later boot keeps it (ADR 009 item 5).

**After an instance started on the new level.** The new level has been written to
and players may have changed it. Choose with Nasir:

- *Level only.* Valid only if the database was not touched by anything that
  depends on the level, such as a mine reset that has written rows. Repeat step 1
  first: stop every instance and the `backup` service and read the shutdown lines,
  since a live server holds the folder open and a later save writes into whatever
  is at that path. Then run the "Before any instance started" commands above. The
  step 3 folder `.replaced-$ZONE-$STAMP` is still on the volume untouched, and
  renaming it back restores the old level exactly. Only if that folder is gone,
  rename the new folder aside by the first `mv` of those commands and extract just
  this zone from the step 2 set:

  ```sh
  wslc run --rm -v "$VOL":/data -v riftal-backups:/backups:ro -e ZONE="$ZONE" mysql:8 bash -c '
    set -euo pipefail
    cd /data/worlds
    [ ! -e "$ZONE" ] || { echo "$ZONE still exists: rename it aside first"; exit 1; }
    tar -xzf /backups/<ts>/worlds/riftal-world.tar.gz -C /data "./worlds/$ZONE"
    chown -R 1000:1000 "$ZONE"'
  ```

  The tar is hand `tar`. No script on `main` restores one level, and `restore.sh`
  does not.
- *Whole set.* `restore.sh` with `BACKUP_SET` the step 2 set, exactly as
  `README.md`, Running it locally (`## Restore` describes it and holds no
  command). It drops and recreates the database and clears every
  world volume before extracting, so it discards everything written to the
  database and every volume since step 2, and it clears the `.replaced-` and
  `.rejected-` folders with the rest. Stop every instance and the `backup` service
  first, since it refuses while any session is connected. Run
  `../migrations/run-migrations.sh` afterwards for the logins, as `README.md`
  says. A restore on a live window is Nasir's call (`ROLLOUT.md`).

After either, repeat step 4b against the restored folder only if it is a built
level, then step 5.

## Production

Everything above applies, with the differences below. **Going to production is
Nasir's, once, and so is every swap on it.** It touches real player data and
nothing in the loop does it, rehearses it on that host or reads its volumes.

- The database name is never `riftal_dev`, and `RIFTAL_DEV_ENV` is never set
  (`ROLLOUT.md`, the section on `riftal_dev` at its end). Each command takes that
  environment's network, volume names and credentials.
- The source is the image layer `/etc/riftal/levels/<zone>` of the tag being
  deployed, built by `build-level` against the same core image, with the manifest's
  `content_sha256` equal to the committed lock's (ADR 009 item 7). No image on
  `main` carries levels yet (riftal-infra#338). Until it does there is no
  production source and this procedure has nothing to copy from.
- Add to step 4: read `content_sha256` from the image's copy of the manifest, run
  from the new tag, and require it equal to the lock's before the swap, not only to
  the volume's after. A tag whose layer disagrees with the lock is not deployed.
- Rolling an image tag back never rolls a level back (ADR 009 item 7). After a
  swap, going back to the previous tag leaves the new level in place. A level goes
  back by Rollback above, whatever the tag does.
- Every instance of the release stops, per `ROLLOUT.md`. The zone lives on one
  instance's volume, but the rollback path is `restore.sh`, which needs every
  session closed.
- A zone that is another instance's after a split is swapped on that instance's
  volume. Two instances never list the same zone.
- Keep the step 2 set out of retention's reach until Nasir has signed the swap off.

## Testing

Nothing tests this procedure. The commands are shell on a volume and have no
selftest. A rehearsal on throwaway volumes, named `riftal_smoke_` with none of the
guard's words in the name, is possible once `build-level` produces a source to copy
from. Until then the document has been checked against the scripts it cites and
nothing else.
