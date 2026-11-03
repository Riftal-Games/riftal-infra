# Replacing a live zone level

The operator procedure for ADR 009 item 8 (riftal-pm
`docs/decisions/009-zone-levels-are-built-not-committed.md`). Seeding never replaces a
level folder that exists, so a revised recipe changes only what a new volume gets.
Swapping the folder on a volume that already holds the zone is this procedure.

**This is Nasir's, by hand, every time.** On production it touches real player data. On
the dev stack it touches `riftal-world`, which is not a throwaway volume. No agent runs
the swap, the restore or any step that writes to a volume that is not `riftal_smoke_`
prefixed. The guard reads command text only and is not the control for these steps.
Never rephrase a command the guard denied.

The steps were rehearsed end to end on 2026-11-03 against `riftal_smoke_` volumes, and
every exit below was taken. The transcript, each command with its output and exit code,
is on riftal-infra#1305. Where this file says "observed", the transcript shows it.

## Names

A zone name matches `^[a-z0-9_]+$` (`instance-levels-check.sh`) and contains none of
`world`, `player` or `backup` (ADR 009 item 2). Every volume, container and network of a
rehearsal starts with `riftal_smoke_` and contains none of those words either.

## Preconditions

1. The zone has a recipe and lock committed on `main`, and the replacement was built
   from that lock's commit on the core image the lock records as `core_image`. A
   different `content_sha256` on the same core image is a build failure, not a map change
   (ADR 009, Consequences). Today only `designer/levels/lumber.lock.json` exists.
2. The level folder's name is the zone's name. On the dev stack the instance's default
   level is `mine_a` (`../images/compose.yaml`, `--level-name=mine_a`), in
   `/data/worlds/mine_a` on `riftal-world`.
3. The old folder is lost to the live path. Whatever players put in it goes with it. A
   plot, or any zone with containers they filled, does not reset (ADR 009,
   Instance-split impact). A saved position inside the old level may land inside solid
   blocks of the new one. Nasir decides per zone whether that is acceptable.
4. The window is announced (`WIPE.md` step 1, `ROLLOUT.md`).
5. The build volume holds the level folder at its root, with `level-manifest.json`
   beside `level.dat`, holding `content_sha256` and `tree_sha256`
   (`../designer/designer/level_engine.py`, `build`). That is the format step 4 reads.

## Variables

Commands are `docker`. On the dev PC they run in the WSL distro:
`wsl -d Ubuntu-26.04 -u runner --exec docker ...` with repo paths under `/mnt/c/`. They
were rehearsed there only. `wslc` takes the same verbs but was not run.

```sh
INFRA=/mnt/c/Users/nasir/riftal-games/riftal-infra
set -a; . "$INFRA/images/.env"; set +a
NET=riftal-dev
DB=riftal_dev
export VOL=riftal-world SETS=riftal-backups ZONE=mine_a
export SRC=riftal_smoke_level_$ZONE
INSTANCE=<the instance container, from docker ps>
BACKUP_SVC=<the backup container, or leave empty if none runs>
```

A rehearsal sets `NET`, `DB`, `VOL`, `SETS` and `SRC` to `riftal_smoke_` names. Its
instance was the lock's `core_image` with no game plugins, on a volume whose generated
`lumber` stood in for the stack's generated `mine_a`.

## Steps

### 1. Stop everything that writes

Stop every instance with a grace period, never a kill: an abrupt halt can corrupt a
level mid-write. PocketMine traps SIGTERM into the same `shutdown()` as `stop`.

```sh
docker ps --format '{{.Names}}'
T1="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker stop -t 60 "$INSTANCE"
docker logs --since "$T1" "$INSTANCE" 2>&1 | grep -E 'Unloading world|Stopping other threads'
docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$INSTANCE"
```

Repeat for every other instance in the `docker ps` output. The pass is both log lines
and `exited 0`. `--since` is needed because a container's log holds every earlier boot:
without it the grep matched 10 lines from earlier stops. `docker stop` itself exits 0
even when it had to kill the container.

Then the `backup` service, if one runs. The wslc dev stack runs none, so there is
nothing to stop and step 6 is skipped. Stop it between runs, when its last log line is
`applying retention`, for the reasons in `WIPE.md` step 2: a scheduled run between
steps 2 and 6 takes a retention slot, and a run killed part way leaves a `.lock` that
fails step 2 until it is `LOCK_MAX_AGE_MINUTES` old.

```sh
docker logs "$BACKUP_SVC" 2>&1 | tail -3
docker stop -t 10 "$BACKUP_SVC"
```

`backup-loop.sh` runs as PID 1 under bash, which ignores SIGTERM, so the stop ends
`exited 137` after the grace period (observed). Between runs that is harmless. Under
compose, `docker compose -f "$INFRA/images/compose.yaml" stop backup` is the same stop.

**Exit: an instance did not log both lines or did not exit 0.** Nothing has been
written yet. A stand-in that ignores SIGTERM ended `exited 137` with no matching line
(observed). Do not take the backup: the level on disk is the last save, not the
instance's state. Start the instance again (step 5) and stop it again. A second unclean
stop is Nasir's. Then step 6.

### 2. Take a backup set, and verify it

One `backup.sh` run after the stop, with one read-only mount per instance volume (the
list the `backup` service mounts in `compose.yaml`; add a `-v` line for each other
volume). The image is `riftal-backup`, the one that service builds: `backup.sh` takes
`flock` on a `server.lock` a down volume still holds, and `mysql:8` has no `flock`.

```sh
docker run --rm -m 1g --cpus 1 --network "$NET" \
  -v "$INFRA/deploy:/deploy:ro" -v "$SETS":/backups \
  -v "$VOL":/worlds/"$VOL":ro \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE="$DB" -e BACKUP_RETENTION="${BACKUP_RETENTION:-10}" \
  riftal-backup bash /deploy/backup.sh
```

The success line is `backup <ts>: complete at /backups/<ts>`. Put `<ts>` in `SET`, then
verify the set; the set is the fallback rollback, so record it:

```sh
export SET=<ts>
docker run --rm -m 1g --cpus 1 -v "$SETS":/backups:ro -e SET -e VOL -e ZONE mysql:8 bash -c '
  set -euo pipefail
  cd "/backups/$SET"
  [ -s mysql.sql ] || { echo "mysql.sql is missing or empty"; exit 1; }
  grep -q "^  - $VOL:" manifest.txt || { echo "manifest.txt does not list $VOL"; exit 1; }
  for t in worlds/*.tar.gz; do tar -tzf "$t" >/dev/null; echo "ok $t"; done
  tar -tzf "worlds/$VOL.tar.gz" | grep -qx "./worlds/$ZONE/level.dat" || { echo "the tar holds no $ZONE"; exit 1; }
  echo "set $SET verified"'
```

Verified means the `complete at` line, an `ok` per tar, and `set <ts> verified` with
exit 0. The tar entries start with `./` because `backup.sh` tars each volume from its
root.

**Exit: no set, or an unverified one.** Nothing has been written to any instance volume.
Observed: a refused database login ended `failed, exit 1` with no `complete at` line, no
new set and no `.partial`. A tar cut short failed `tar -tzf` with exit 2. A set that
does not list the volume stopped at the `manifest.txt` line. Fix the cause and run step
2 again, or go to step 5 then step 6. Nothing stands in for the set: not the build
volume, not the `.replaced-` folder of step 3.

Retention prunes the set `BACKUP_RETENTION - 1` intervals after step 6: 54 hours at the
defaults (`WIPE.md` step 3). Any other `backup.sh` run into the same `BACKUP_ROOT` brings
that forward, and so does each start of the service. A window that could outlast that
copies the set out of `BACKUP_ROOT` before step 6, to where Nasir says (`ROLLOUT.md`).

### 3. Swap the folder

The source is mounted read-only and never the target. The new folder is copied in under
a temporary name, the live one is renamed aside, and the new one is renamed into place.
Nothing is deleted. The container runs as uid 1000, the `pocketmine` user, so the copy
is owned by it with no `chown`, and a source file that user cannot read fails the copy.

```sh
export STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
docker run --rm -m 1g --cpus 1 --user 1000:1000 \
  -v "$VOL":/data -v "$SRC":/src:ro -e ZONE -e STAMP \
  mysql:8 bash -c '
    set -euo pipefail
    cd /data/worlds
    [ -d "$ZONE" ] || { echo "no live $ZONE: this is a seed, not a replace"; exit 1; }
    [ -f /src/level.dat ] || { echo "no built level at the source root"; exit 1; }
    [ ! -e ".incoming-$ZONE-$STAMP" ] && [ ! -e ".replaced-$ZONE-$STAMP" ] || { echo "a leftover name exists"; exit 1; }
    cp -a /src ".incoming-$ZONE-$STAMP"
    mv "$ZONE" ".replaced-$ZONE-$STAMP"
    mv ".incoming-$ZONE-$STAMP" "$ZONE"
    echo "swapped $ZONE, old level at .replaced-$ZONE-$STAMP"'
```

`STAMP` lives in this shell only. The last line prints it; every rollback needs it, so
copy it into the new shell with `export STAMP=<stamp>`. If the line was lost, read the
stamp off the volume:
`docker run --rm -v "$VOL":/data:ro mysql:8 ls -A /data/worlds`.

**Exit: a refusal.** Each guard prints and exits 1 before anything is written. Observed
with a zone that does not exist, a stamp whose `.replaced-` exists, and a source with no
`level.dat`. Fix the input and run again, or step 5 then step 6.

**Exit: the copy fails.** Observed with a source file mode 000: `cp: cannot open
'/src/level.dat' for reading: Permission denied`, exit 1. The live level's tree hash was
unchanged and `.incoming-<zone>-<stamp>` stayed on the volume. No rollback is needed.
Run step 3 again with a new stamp, or step 5 then step 6. The partial copy is settled in
step 7.

**Exit: step 3 dies between its renames.** `<zone>` is absent, and `.replaced-<zone>-<stamp>`
holds the old level. Rename it back by hand, as uid 1000:

```sh
docker run --rm -m 1g --cpus 1 --user 1000:1000 -v "$VOL":/data -e ZONE -e STAMP \
  mysql:8 bash -c 'cd /data/worlds && mv ".replaced-$ZONE-$STAMP" "$ZONE"'
```

Observed: the tree hash of the restored folder equals the one taken before step 3. Never
start an instance while `<zone>` is absent: for a zone that is the default level, core
generates plain terrain there and every later boot keeps it (ADR 009 item 5). Then step 5,
then step 6.

### 4. Verify the swap, instance still stopped

Run before any instance starts, since a boot writes to the level. The check recomputes
the tree hash of the live folder, the way `images/plugins/seed-levels.sh` and
`level_engine.py` `read_tree` do, and requires it equal to the manifest's `tree_sha256`.
It then requires the manifest's `content_sha256` equal to the committed lock's.

```sh
docker run --rm -m 1g --cpus 1 -v "$VOL":/data:ro -v "$INFRA/designer/levels":/levels:ro -e ZONE mysql:8 bash -c '
  set -euo pipefail
  digest() { sed -n "s/^ *\"$2\": *\"\\([0-9a-f]\\{64\\}\\)\",\\{0,1\\} *\$/\\1/p" "$1"; }
  cd "/data/worlds/$ZONE"
  tree="$(find . -type f ! -path ./level-manifest.json -printf "%P\0" | LC_ALL=C sort -z | xargs -0 -r sha256sum -- | sha256sum | cut -d" " -f1)"
  want="$(digest level-manifest.json tree_sha256)"
  content="$(digest level-manifest.json content_sha256)"
  lock="$(digest "/levels/$ZONE.lock.json" content_sha256)"
  [ -n "$want" ] && [ -n "$content" ] && [ -n "$lock" ] || { echo "the manifest or the lock holds no digest"; exit 1; }
  [ "$tree" = "$want" ] || { echo "tree $tree is not the manifest tree $want"; exit 1; }
  [ "$content" = "$lock" ] || { echo "content_sha256 $content is not the lock $lock"; exit 1; }
  echo "step 4 passed: tree $tree, content_sha256 $content"'
```

It passes only on exit 0 and the `step 4 passed` line. A manifest without a digest is
refused by the `holds no digest` line, and a missing one by the `sed` under `set -e`, so
neither passes as two equal blanks. `content_sha256` is a hash of block
states read through DesignBridge, which nothing on `main` recomputes from a folder: the
check compares the build's own value with the lock. The tree hash proves the files are
the ones the build published. A swap is not a seed, so no boot line carries
`content_sha256`.

**Exit: a check fails.** Do not start an instance. Observed: a source with one altered
file printed `tree ... is not the manifest tree ...`, and a manifest with another
`content_sha256` printed `content_sha256 ... is not the lock ...`, both exit 1. Go to
Rollback, "Before any instance started".

### 5. Start

One instance at a time, database first, as `ROLLOUT.md`. `docker start` reruns the
container's own command. Read the log from this start only, never the exit code:

```sh
T0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker start "$INSTANCE"
docker logs --since "$T0" "$INSTANCE" > boot.log 2>&1
grep -c '\]: Done (' boot.log
grep -cE '/(EMERGENCY|ALERT|CRITICAL|ERROR)\]' boot.log
grep -E 'Preparing world|Generating spawn terrain' boot.log
```

Wait for `Done (` before the first read. The pass is one `Done (` line, zero severe
lines, `Preparing world "<zone>"` and no `Generating spawn terrain`, which means the
level came off the volume. `../images/loads-check.sh boot.log` checks the first two and
that `RiftalCustody` enabled before the first world. On the rehearsed instance it printed
`LOADS FAIL: RiftalCustody was never enabled` and nothing else, since that instance ran
no plugins. The stack's seed step and the zone plugin's loader were not rehearsed; a
`has no world folder` or `MineWorldLoader` WARNING is a failure.

This is LOADS. Whether a client can walk the new level is a separate verdict that only a
client run or Nasir gives. A boot that fails these reads goes to Rollback, "After an
instance started".

### 6. Start the `backup` service

If one runs: `docker start "$BACKUP_SVC"` (under compose `docker compose -f
"$INFRA/images/compose.yaml" start backup`). `backup-loop.sh` runs `backup.sh` at once, so
the first set after the swap is taken then. Read its log for `complete at`.

**Exit: the run failed `capture fence raise answered 'busy'`.** A live lease blocks it,
after a whole-set rollback the one it restored. The loop logs it and sleeps
`BACKUP_INTERVAL_SECONDS` (6 hours) with no set. Wait out `raised_until` (Rollback, whole
set), then `docker restart "$BACKUP_SVC"`, which runs `backup.sh` at once (not rehearsed).

### 7. Settle the old folder

`.replaced-<zone>-<stamp>` stays on the volume until Nasir removes it. So do
`.rejected-<zone>-<stamp>` after a rollback and a `.incoming-<zone>-<stamp>` a failed copy
left. While any exists it is inside every later set's volume tar (observed). The set from
step 2 is the durable record either way. Nothing in the loop deletes them.

## Rollback

Choose by where the failure happened. Every path ends at step 5, then step 6. For a level
that was built, repeat step 4 against the restored folder first.

**Before any instance started** (step 3 or 4 failed). Nothing wrote to either folder.
Rename back, which restores the exact bytes and loses nothing:

```sh
docker run --rm -m 1g --cpus 1 --user 1000:1000 -v "$VOL":/data -e ZONE -e STAMP mysql:8 bash -c '
  set -euo pipefail
  cd /data/worlds
  [ -d ".replaced-$ZONE-$STAMP" ] || { echo "no old level to put back"; exit 1; }
  [ ! -e ".rejected-$ZONE-$STAMP" ] || { echo "a leftover name exists"; exit 1; }
  mv "$ZONE" ".rejected-$ZONE-$STAMP"
  mv ".replaced-$ZONE-$STAMP" "$ZONE"'
```

Observed after both failed checks of step 4: the folder's tree hash equalled the one
taken before the swap. The guards print `no old level to put back` when `.replaced-` is
absent and `a leftover name exists` when `.rejected-` is present, exit 1, nothing moved.

**After an instance ran on the new level.** The new level has been written to and players
may have altered it. Choose with Nasir. First repeat step 1: a live server holds the
folder open, and a later save writes into whatever is at that path.

- *Level only.* Valid only if the database was not touched by anything that depends on
  the level, such as a mine reset that has written rows. With `.replaced-<zone>-<stamp>`
  still on the volume, run the rename-back block above. Observed: the folder equalled the
  one step 1 left, byte for byte by tree hash, and booted with `Preparing world` and no
  `Generating spawn terrain`. If the folder is gone, rename the new one aside and extract
  just this zone from the step 2 set, in one run (`SET` as in step 2):

  ```sh
  docker run --rm -m 1g --cpus 1 --user 1000:1000 -v "$VOL":/data -v "$SETS":/backups:ro -e ZONE -e VOL -e STAMP -e SET mysql:8 bash -c '
    set -euo pipefail
    cd /data/worlds
    [ ! -e ".rejected-$ZONE-$STAMP" ] || { echo "a leftover name exists"; exit 1; }
    tar -tzf "/backups/$SET/worlds/$VOL.tar.gz" | grep -qx "./worlds/$ZONE/level.dat" || { echo "the tar holds no $ZONE"; exit 1; }
    mv "$ZONE" ".rejected-$ZONE-$STAMP"
    tar -xzf "/backups/$SET/worlds/$VOL.tar.gz" -C /data "./worlds/$ZONE"
    echo "extracted $ZONE from set $SET"'
  ```

  Use a new `STAMP`. Observed: the extracted folder is owned by uid 1000 and equals the
  step 1 level by tree hash. The tar is hand `tar`; no script on `main` restores one
  level, and `restore.sh` does not.
- *Whole set.* `restore.sh` with `BACKUP_SET` the step 2 set. It drops and recreates the
  database and clears every volume it holds before extracting, so it discards everything
  written to the database and those volumes since step 2, the `.replaced-` and
  `.rejected-` folders included. Stop every instance and the `backup` service first: it
  refuses while any session is connected (`README.md`, Restore). A restore on a live
  window is Nasir's call (`ROLLOUT.md`).

  ```sh
  docker run --rm -m 1g --cpus 1 --network "$NET" \
    -v "$INFRA/deploy:/deploy:ro" -v "$SETS":/backups:ro -v "$VOL":/worlds/"$VOL" \
    -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
    -e MYSQL_DATABASE="$DB" -e BACKUP_SET="/backups/$SET" \
    mysql:8 bash /deploy/restore.sh
  ```

  Add a `-v` line for each volume in the set. Observed: it ended `complete, database
  ... and 1 world volume(s) rebuilt`, a table row written after step 2 read its step 2
  value again, `worlds/` held only `lumber`, and the folder equalled the step 1 level.
  Run `../migrations/run-migrations.sh` afterwards for the logins (`README.md`); the
  rehearsal database held none, so it was not run.

  **The step 6 start waits.** The step 2 run dumped the database with the capture fence
  raised, so the restored `capture_fence` row holds that lease and `backup.sh` answers
  `busy` until it passes: at most `CAPTURE_FENCE_MAX_SECONDS` (1800 s) after the set's
  timestamp. `restore.sh` does not lower it; riftal-infra#1100 does, and removes the wait.
  Observed: the first run after the restore failed `busy`, and a run after `raised_until`
  passed ended `complete at`. Start step 6 when `seconds_left` is 0 or less or NULL:

  ```sh
  docker run --rm -m 1g --cpus 1 --network "$NET" mysql:8 mysql -h mysql -uroot \
    -p"$MYSQL_ROOT_PASSWORD" "$DB" -e 'SELECT raised_until, TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(3), raised_until) AS seconds_left FROM capture_fence WHERE id = 1'
  ```

## Production

Everything above applies, with the differences below. **Going to production is Nasir's,
once, and so is every swap on it.** It touches real player data and nothing in the loop
does it, rehearses it on that host or reads its volumes.

- The database name is never `riftal_dev`, and `RIFTAL_DEV_ENV` is never set
  (`ROLLOUT.md`, the section on `riftal_dev` at its end). Each command takes that
  environment's network, volume names and credentials.
- The source is the image layer `/etc/riftal/levels/<zone>` of the tag being deployed,
  built by `build-level` against the same core image. No image on `main` carries levels
  (riftal-infra#338), so this part was not rehearsed.
- Before step 3, read `content_sha256` from the manifest in that layer, run from the new
  tag, and require it equal to the lock's. A tag whose layer disagrees with the lock is
  not deployed. Step 4 then checks the volume as above.
- Rolling an image tag back never rolls a level back (ADR 009 item 7); Rollback above does.
- Every instance of the release stops, per `ROLLOUT.md`, since the whole-set rollback
  needs every session closed. A zone that is another instance's after a split is swapped
  on that instance's volume; two instances never list the same zone.
- Keep the step 2 set out of retention's reach until Nasir has signed the swap off.

## Not rehearsed

The stack's boot chain and seed step, game plugins, a second instance volume, the compose
`backup` service, `restore.sh` refusing on a connected session, the migrations run after
a restore, a client joining, and production. The instance and the `backup` service never
ran together; a real run stops both in step 1 and starts them in steps 5 and 6.
