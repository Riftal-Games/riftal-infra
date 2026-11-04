# Replacing a live zone level

The operator procedure for ADR 009 item 8 (riftal-pm
`docs/decisions/009-zone-levels-are-built-not-committed.md`). Seeding never replaces a
level folder that exists; swapping the folder on a volume that holds it is this procedure.

**This is Nasir's, by hand, every time.** On production it touches real player data. On
the dev stack it touches `riftal-world`, which is not a throwaway volume. No agent runs
the swap or any step that writes to a volume that is not `riftal_smoke_` prefixed, and an
agent works on those only for steps that run neither script: stop, start, swap, check,
rename back and tar extract.

**No agent runs `backup.sh`, `backup-loop.sh` or `restore.sh` outside a committed CI
self-test, on any volume, `riftal_smoke_` volumes included** (ADR 027, riftal-pm
`docs/decisions/027-*`, "What must hold everywhere"). That is step 2, step 6 and the
whole-set rollback. The guard reads command text only and is not the control here. Never
rephrase a command the guard denied.

Steps that run neither script were rehearsed on 2026-11-03 on `riftal_smoke_` volumes
(transcript on riftal-infra#1305). The script-driven exits are shown by CI run
41706915821 (`gh run view 41706915821 --log`, step "Level replace runbook script exits
self-test"), which ended `all 13 scenarios ended as expected: the real scripts pass 17
cases and each of 12 mutants fails exactly its own`, each case going red under a mutant.
"Observed" means the transcript or that run shows it; "not rehearsed" means nothing does.

## Preconditions

1. The zone has a recipe and lock committed on `main`, and the replacement was built
   from that lock's commit on the lock's `core_image`. A different `content_sha256` on
   the same core image is a build failure, not a map change (ADR 009, Consequences).
2. The level folder's name is the zone's name, matching `^[a-z0-9_]+$`
   (`instance-levels-check.sh`) with none of `world`, `player` or `backup` in it (ADR 009
   item 2), as in every volume, container and network of a rehearsal, which also starts
   with `riftal_smoke_`. The dev stack's default level is `mine_a`, in
   `/data/worlds/mine_a` on `riftal-world` (`../images/compose.yaml`).
3. The old folder is lost to the live path, with whatever players put in it. A plot, or
   any zone with containers they filled, does not reset (ADR 009, Instance-split
   impact). A saved position may land inside solid blocks of the new level. Nasir decides
   per zone whether that is acceptable.
4. The window is announced (`WIPE.md` step 1, `ROLLOUT.md`).
5. The build volume holds the level folder at its root, with `level-manifest.json`
   beside `level.dat`, holding `content_sha256` and `tree_sha256`
   (`../designer/designer/level_engine.py`, `build`), the format step 4 reads.

## Variables

Run the `docker` verbs on the engine the stack runs on (`dev-stack.ps1 status` prints
`engine:`; wslc is the default). `riftal-world`, `riftal-backups` and the `mysql` alias
exist separately on each engine, so a command on the other one stops nothing, then swaps
or restores that engine's volumes. For docker, use a shell inside the distro (`wsl -d
Ubuntu-26.04 -u runner`), repo paths under `/mnt/c/`, so that `-e NAME` takes the shell's
exports and `. "$INFRA/images/.env"` resolves. The rehearsal ran there only; the wslc
path was not run.

```sh
INFRA=/mnt/c/Users/nasir/riftal-games/riftal-infra
set -a; . "$INFRA/images/.env"; set +a
NET=riftal-dev
DB=riftal_dev
export VOL=riftal-world SETS=riftal-backups ZONE=<a zone with a lock in designer/levels>
export SRC=riftal_smoke_level_$ZONE
INSTANCE=<the instance container, from docker ps>
BACKUP_SVC=<the backup container, or leave empty if none runs>
treehash() { docker run --rm -m 1g --cpus 1 -v "$VOL":/data:ro -e ZONE mysql:8 bash -c 'cd "/data/worlds/$ZONE" && find . -type f -printf "%P\0" | LC_ALL=C sort -z | xargs -0 -r sha256sum -- | sha256sum | cut -d" " -f1'; }
```

`mine_a` is a `ZONE` here: its lock is `../designer/levels/mine_a.lock.json` and its build
volume `riftal_smoke_level_mine_a`. Define `treehash` in every new shell. A rehearsal sets
`NET`, `DB`, `VOL`, `SETS` and `SRC` to `riftal_smoke_` names, runs the lock's `core_image`
with no game plugins, and uses `lumber` for `mine_a`.

## Steps

### 1. Stop everything that writes

Stop every instance with a grace period, never a kill, which can corrupt a level
mid-write. PocketMine traps SIGTERM into the same `shutdown()` as `stop`.

```sh
docker ps --format '{{.Names}}'
T1="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker stop -t 60 "$INSTANCE"
docker logs --since "$T1" "$INSTANCE" 2>&1 | grep -E 'Unloading world|Stopping other threads'
docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$INSTANCE"
```

Repeat for every other instance in the `docker ps` output. The pass is both log lines
and `exited 0`. `--since` is needed because a container's log holds every earlier boot
(without it the grep matched 10 lines from earlier stops), and `docker stop` itself
exits 0 even when it had to kill the container.

Then the `backup` service, if one runs. The dev stack runs none on either engine, so
there is nothing to stop and step 6 is skipped. Stop it between runs, when its last run
has reached `applying retention`, its `pruning` lines are done and no `dumping database`
line follows (`WIPE.md` step 2): a scheduled run between steps 2 and 6 takes a retention
slot, and a run killed part way leaves a `.lock` that fails step 2 until it is
`LOCK_MAX_AGE_MINUTES` old. Read `docker logs "$BACKUP_SVC" 2>&1 | tail -3`, then
`docker stop -t 10 "$BACKUP_SVC"` (under compose `docker compose -f
"$INFRA/images/compose.yaml" stop backup`). `backup-loop.sh` runs as PID 1 under bash,
which ignores SIGTERM, so the stop is expected to end `exited 137` after the grace
period, harmless between runs (not rehearsed).

**Exit: an instance did not log both lines or did not exit 0.** Nothing has been
written yet. A stand-in that ignores SIGTERM ended `exited 137` with no matching line
(observed). Do not take the backup: the level on disk is the last save, not the
instance's state. Start the instance again (step 5), stop it again, then step 6. A
second unclean stop is Nasir's.

### 2. Take a backup set, and verify it

One `backup.sh` run after the stop, with one read-only mount per instance volume (the
list the `backup` service mounts in `compose.yaml`; add a `-v` line for each other).
The image is `riftal-backup`, the one that service builds: `backup.sh` takes `flock` on
a `server.lock` a down volume still holds, and `mysql:8` has no `flock`.

```sh
docker run --rm -m 1g --cpus 1 --network "$NET" \
  -v "$INFRA/deploy:/deploy:ro" -v "$SETS":/backups \
  -v "$VOL":/worlds/"$VOL":ro \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_DATABASE="$DB" -e BACKUP_RETENTION="${BACKUP_RETENTION:-10}" \
  riftal-backup bash /deploy/backup.sh
```

The success line is `backup <ts>: complete at /backups/<ts>`. Put `<ts>` in `SET` and
verify the set, which is the fallback rollback:

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
root. CI run 41706915821 takes a set and runs this verification as written
(`set-run-exit0`, `set-complete-line`, `set-verified`).

**Exit: no set, or an unverified one.** Nothing has been written to any instance volume.
Observed in that run, with a refused database login: exit non-zero, a `failed, exit 1`
line, no `complete at` line, no new set and no `.partial` (`refused-*`). Observed in the
transcript: a tar cut short failed `tar -tzf` with exit 2, and a set missing the volume
stopped at the `manifest.txt` line. Fix the cause and run step 2 again, or go to step 5
then step 6. Nothing stands in for the set: not the build volume, not `.replaced-`.

Retention prunes the set `BACKUP_RETENTION - 1` intervals after step 6: 54 hours at the
defaults (`WIPE.md` step 3), sooner with any other run into the same `BACKUP_ROOT`. A
window that could outlast that copies the set out first, to where Nasir says.

### 3. Swap the folder

The source is mounted read-only and never the target. The new folder is copied in under
a temporary name, the live one is renamed aside, and the new one is renamed into place.
Nothing is deleted. The container runs as uid 1000, the `pocketmine` user, so the copy
is owned by it with no `chown`, and a source file that user cannot read fails the copy.
The live folder's tree hash is recorded first, beside `STAMP`, because every rollback
compares against it: a booted level no longer matches its manifest (a boot rewrites
`level.dat` and the LevelDB files, ADR 009). An empty `OLD_TREE`: do not swap.

```sh
export STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
export OLD_TREE="$(treehash)"
echo "STAMP=$STAMP OLD_TREE=$OLD_TREE"
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

`STAMP` and `OLD_TREE` live in this shell only, and the `echo` is their only record.
Every rollback needs them: copy them into a new shell with `export STAMP=<stamp>
OLD_TREE=<hash>`. A lost stamp is on the volume (`ls -A /data/worlds` in a `mysql:8`
run); a lost hash is not.

**Exit: a refusal.** Each guard exits 1 before any write (observed: a missing zone, a
taken stamp, no `level.dat`). Fix the input and run again, or step 5 then step 6.

**Exit: the copy fails.** Observed with a source file mode 000: `cp: cannot open
'/src/level.dat' for reading: Permission denied`, exit 1, the live tree hash unchanged,
`.incoming-<zone>-<stamp>` left (step 7). Nothing to roll back: run step 3 again with a
new stamp, or step 5 then step 6.

**Exit: step 3 dies between its renames.** `<zone>` is absent, and
`.replaced-<zone>-<stamp>` holds the old level. Rename it back by hand, as uid 1000:

```sh
docker run --rm -m 1g --cpus 1 --user 1000:1000 -v "$VOL":/data -e ZONE -e STAMP \
  mysql:8 bash -c 'set -euo pipefail; cd /data/worlds; mv ".replaced-$ZONE-$STAMP" "$ZONE"'
```

Check the restored folder against `OLD_TREE` as in Rollback; observed equal. Never start
an instance while `<zone>` is absent: for a default level, core generates plain terrain
there and every later boot keeps it (ADR 009 item 5). Then step 5, then step 6.

### 4. Verify the swap, instance still stopped

Run before any instance starts, since a boot writes to the level. The check recomputes
the live folder's tree hash, as `images/plugins/seed-levels.sh` and `level_engine.py`
`read_tree` do, requires it equal to the manifest's `tree_sha256`, then requires the
manifest's `content_sha256` equal to the committed lock's.

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

It passes only on exit 0 and the `step 4 passed` line. `content_sha256` is a hash of
block states read through DesignBridge, which nothing on `main` recomputes from a
folder: the check compares the build's own value with the lock, and the tree hash proves
the files are the ones the build published. A swap is not a seed, so no boot line
carries it.

**Exit: a check fails.** Do not start an instance. Observed: a source with one altered
file printed `tree ... is not the manifest tree ...`, and a manifest with another
`content_sha256` printed `... is not the lock ...`, both exit 1. Go to Rollback,
"Before any instance started".

### 5. Start

One instance at a time, database first, as `ROLLOUT.md`. `docker start` reruns the
container's own command. Read the log from this start only, never the exit code:

```sh
T0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker start "$INSTANCE"
for _ in $(seq 60); do sleep 5
  docker logs --since "$T0" "$INSTANCE" 2>&1 | grep -q '\]: Done (' && break; done
docker logs --since "$T0" "$INSTANCE" > boot.log 2>&1
grep -c '\]: Done (' boot.log
grep -cE '/(EMERGENCY|ALERT|CRITICAL|ERROR)\]' boot.log
grep -E 'Preparing world|Generating spawn terrain' boot.log
```

The loop waits up to five minutes for `Done (`. The pass is one `Done (` line, zero severe
lines, `Preparing world "<zone>"` and no `Generating spawn terrain`, which means the
level came off the volume. `../images/loads-check.sh boot.log` checks the first two and
that `RiftalCustody` enabled before the first world; the rehearsed instance ran no
plugins and printed only `LOADS FAIL: RiftalCustody was never enabled`. A `has no world
folder` or `MineWorldLoader` WARNING is a failure. This is LOADS, not a client walking
the level. A boot failing these reads goes to Rollback, "After an instance started".

### 6. Start the `backup` service

If one runs: `docker start "$BACKUP_SVC"` (under compose `docker compose -f
"$INFRA/images/compose.yaml" start backup`). `backup-loop.sh` runs `backup.sh` at once,
so the first set after the swap is taken then. Read its log for `complete at`.

**Exit: the run failed `capture fence raise answered 'busy'`.** Another run's live lease
blocks it: `backup.sh` exits non-zero, logs the reason before any dump, writes no set and
leaves that run's fence raised (`deploy/selftest.sh`, ADR 027 P7; CI run 41706915821,
step "Backup job self-test"). The loop then sleeps `BACKUP_INTERVAL_SECONDS` (6 hours).
Wait out the lease, then `docker restart "$BACKUP_SVC"` (the sleep and the restart are
not rehearsed).

### 7. Settle the old folder

`.replaced-<zone>-<stamp>` stays on the volume until Nasir removes it, as do
`.rejected-<zone>-<stamp>` after a rollback and `.incoming-<zone>-<stamp>` after a failed
copy, and each is inside every later set's volume tar, since `backup.sh` tars each volume
from its root. The step 2 set is the durable record. Nothing in the loop deletes them.

## Rollback

Choose by where the failure happened. Every path ends at step 5, then step 6, and before
step 5 the restored folder is checked against the hash recorded in step 3 (step 4 cannot,
since a boot rewrites files the manifest hashes). On a mismatch do not start an
instance; it is Nasir's.

```sh
[ "$(treehash)" = "$OLD_TREE" ] && echo "restored level equals OLD_TREE" || echo "MISMATCH"
```

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

**After an instance ran on the new level.** Choose with Nasir. First repeat step 1: a
live server holds the folder open, and a later save writes into whatever is at that path.

- *Level only.* Valid only if nothing in the database depends on the level, such as a
  mine reset that has written rows. With `.replaced-<zone>-<stamp>` still on the volume,
  run the rename-back block above. Observed: the folder equalled the one step 1 left by
  tree hash, and booted with `Preparing world` and no `Generating spawn terrain`. If the
  folder is gone, rename the new one aside and extract just this zone from the step 2
  set, in one run (`SET` as in step 2), under a new `STAMP` so that
  `.rejected-<zone>-<stamp>` does not exist:

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

  Observed: the extracted folder is owned by uid 1000 and equals the step 1 level by tree
  hash. It is hand `tar`; `restore.sh` restores no single level.
- *Whole set.* `restore.sh` with `BACKUP_SET` the step 2 set. It drops and recreates the
  database and clears every volume it holds before extracting, discarding everything
  written since step 2, the `.replaced-` and `.rejected-` folders included. Stop every
  instance and the `backup` service first: it refuses while any session is connected
  (`README.md`, Restore). A restore on a live window is Nasir's call (`ROLLOUT.md`).

  ```sh
  docker run --rm -m 1g --cpus 1 --network "$NET" \
    -v "$INFRA/deploy:/deploy:ro" -v "$SETS":/backups:ro -v "$VOL":/worlds/"$VOL" \
    -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
    -e MYSQL_DATABASE="$DB" -e BACKUP_SET="/backups/$SET" \
    riftal-backup bash /deploy/restore.sh
  ```

  Add a `-v` line for each volume in the set. Observed in CI run 41706915821: it ended
  `complete, database ... and 1 world volume(s) rebuilt` (`restore-complete-line`), a
  table row written after the set read its set value again (`restore-row-at-set`),
  `worlds/` held only the zone (`restore-volume-rebuilt`), and the level folder's tree
  hash equalled the one before the swap (`restore-level-tree`). Run
  `../migrations/run-migrations.sh` afterwards for the logins (`README.md`); not
  rehearsed.

  `restore.sh` lowers the `capture_fence` row of a fenced set, and every step 2 set is
  fenced, so the first `backup.sh` run after the restore completes at once, with no wait.
  Observed in the same run: `restore-fence-lowered` (`request_id` and `raised_until`
  both NULL), then `first-run-exit0`, `first-run-complete-line`, `first-run-new-set`.

## Production

Everything above applies, with the differences below. **Going to production is Nasir's,
once, and so is every swap on it.** Nothing in the loop does it or reads its volumes.

- The database is never `riftal_dev` and `RIFTAL_DEV_ENV` is never set (`ROLLOUT.md`).
  Each command takes that environment's network, volume names and credentials.
- The source is the image layer `/etc/riftal/levels/<zone>` of the tag being deployed,
  built by `build-level` against the same core image. No image on `main` carries levels
  (riftal-infra#338), so this part was not rehearsed. Before step 3, read
  `content_sha256` from the manifest in that layer, run from the new tag; a tag whose
  layer disagrees with the lock's is not deployed.
- Rolling an image tag back never rolls a level back (ADR 009 item 7); Rollback does.
- Every instance of the release stops (`ROLLOUT.md`), since the whole-set rollback needs
  every session closed. After a split, a zone is swapped on its own instance's volume.
- Keep the step 2 set out of retention's reach until Nasir has signed the swap off.

## Not rehearsed

The stack's boot chain and seed step, game plugins, a second instance volume, the compose
`backup` service and its stop ending `exited 137`, the loop's sleep after a `busy` run
and the restart, `restore.sh` refusing on a connected session, the migrations after a
restore, the wslc engine, a client joining, production, and the instance and the
`backup` service together.
