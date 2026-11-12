# Rollout notes

Ordering constraints that the fixed rollout order in `../CLAUDE.md`
(migrations, then instances one at a time, then the proxy) does not cover on
its own. Read this before every `/deploy-release` and before any manual
migration run against a database that instances are using. Newest constraints
go at the end; an entry stays as long as a database or an image tag it
describes can still be met.

## The general rule: a migration or grants change that needs a matching plugin build

Most migrations are additive and safe under the serial rollout: an instance on
the previous image tag keeps working against the migrated schema, so instances
can be replaced one at a time and rolled back to the previous tag.

A migration is **coupled** when that is not true: when an instance on an older
plugin build, running against the migrated schema, fails or writes rows the
schema now treats differently. The other direction, a newer build against the
unmigrated schema, is not part of the test: migrations always run before any
instance starts on the newer build, so the procedure already rules it out.

A `grants.sql` change is coupled the same way. `run-migrations.sh` applies the
`GRANTS_FILE` it is given on every run, a run with nothing pending included
(`../migrations/run-migrations.sh:309`), so the file's REVOKEs reach the
database on every run, and on a fresh server a role holds only what the file
grants. `grants-revoke-check.sh` belongs in `/deploy-release` stage 1, before
the migrations run, and refuses a REVOKE that is new against a tag that can
still run (`README.md`, Grants REVOKE check). A change is coupled
when a plugin build that an instance may still run, or be rolled back to,
needs a privilege the file revokes or does not grant: every statement of that
build that uses it fails with ERROR 1142 or 1143.

For a coupled migration or grants change:

- The migration or grants change and the plugin build that matches it reach
  every instance together. No instance runs the older build against a schema
  with the migration applied or grants with the change, and no instance runs
  the newer build against a schema without the migration.
- Since one image serves every instance, that means stopping every instance
  cleanly before the migration run, then starting each on the new image tag.
  The serial, one-at-a-time replacement does not apply to that window: the
  window is a full stop, so announce it in Discord before it opens.
- The previous image tag is not a rollback target once the migration or the
  grants change has applied. The only rollback is an image tag that carries
  the matching build of every coupled migration and every coupled grants
  change the run applied.
- Every instance stops before anything else in the window happens, the
  backup included.
- The backup is one `backup.sh` run taken after that stop, its set name
  recorded, as in The window's backup and restore, below.
- A restore of that set is a rollback only until the first instance on the
  new tag admits a player. After that it is destructive (`README.md`, Restore:
  the database is dropped and every world directory is cleared, so everything
  players did since the backup is gone), it is never a rollback, and it is
  Nasir's call.
- Write the coupled pair into the release's "what is shipping" list and into
  its rollback path before the window opens, naming the migration number or
  the `grants.sql` change, and the plugin change.
- The runner applies every pending migration in one run, then the whole
  grants file, so a run can cross several coupled migrations and coupled
  grants changes. The image tag the instances start on, and every rollback
  tag, must carry the matching build of each coupled migration and each
  coupled grants change that run applies, not only the first.
- Whoever lands a coupled migration or grants change in `riftal-game` files
  an `owner:infra` issue to add its entry here.

## The window's backup and restore

A restore is never a routine step of a window. The backup below is taken in
every window; the restore is the recovery for a window that cannot go on.

Commands are for the dev stack, with the variables set as in `README.md`,
Running it locally. Elsewhere they take that environment's network, volume
names, database name and credentials, and the same scripts. That database
name is never `riftal_dev`: see the section "`riftal_dev` and the wipe's
`RIFTAL_DEV_ENV=1` belong to the dev stack" at the end of this file.

### Take the backup

Every instance has stopped cleanly: `stop` on stdin, then its shutdown line.

1. Run `backup.sh` once, with one read-only mount per instance world volume,
   the same list the `backup` service mounts in `../images/compose.yaml`. The
   image is `riftal-backup` (`README.md`, Running it locally), because
   `backup.sh` takes `flock` on a `server.lock`, which `mysql:8` does not carry:

   ```sh
   timeout 120 wslc run --rm --network riftal-dev \
     -v "$INFRA/deploy:/deploy:ro" \
     -v riftal-backups:/backups \
     -v riftal-world:/worlds/riftal-world:ro \
     -v riftal-world-b:/worlds/riftal-world-b:ro \
     -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD" \
     -e MYSQL_DATABASE=riftal_dev -e BACKUP_RETENTION="${BACKUP_RETENTION:-10}" \
     riftal-backup bash /deploy/backup.sh
   ```

2. Read its log. Success is `backup <ts>: complete at <set>`, for example
   `complete at /backups/20261012T120000000000000Z` (`backup.sh:265`). A run
   that ends any other way left no set behind (`backup.sh:172`); fix the cause
   and run it again. `another run already holds the lock` means the `backup`
   service's scheduled run is under way: wait for it to finish, then run
   again. Record this run's set only, never a scheduled one.
3. Write `<set>` into the release's rollback path before the migrations run.
   Read its `manifest.txt`: `world_volumes:` must list every instance world
   volume, since a restore rebuilds only the worlds the set holds.
4. Nothing stands in for the set, a database-only dump least of all.
   `restore.sh` refuses a set with no `worlds/` directory or no world tar in
   it (`restore.sh:29`, `:34`).
5. Retention prunes the set once `BACKUP_RETENTION` later runs complete,
   scheduled ones included: 2.5 days at the defaults (`README.md`, Retention).
   A window that could outlast that copies the set out of `BACKUP_ROOT` first,
   and where to is Nasir's call.

### Count `gangs` before a run that applies 0010

After the backup and before the migrations:

```sh
timeout 120 wslc run --rm --network riftal-dev \
  -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
  mysql:8 mysql --host=mysql --user=root -N -B riftal_dev \
  -e 'SELECT COUNT(*) FROM gangs'
```

It prints one bare number. Record it next to the set name; 0010's step 3
compares the backfill count with it. Every instance is stopped, so nothing
writes to `gangs` in between.

### When a restore is a rollback

Restoring the recorded set rebuilds the database and every world volume to
the moment of the stop. That loses nothing a player did only until the first
instance on the new tag admits a player. An instance has admitted one once
any of its logs since it started on the new tag holds a `logged in with
entity id` line (pmmp-core `resources/translations/eng.ini:557`). A bot
counts. A log that cannot be read in full counts as an admission.

After the first admission, there is no restore step in this file. A restore
then is destructive, never a rollback, and Nasir's call (`../CLAUDE.md`,
Rollout rules).

Before it:

1. Stop cleanly every instance that started on the new tag, and the `backup`
   service.
2. Run `restore.sh` with `BACKUP_SET` the recorded set, as in `README.md`,
   Running it locally. Success is `restore <set>: complete, database <db> and
   <n> world volume(s) rebuilt` (`restore.sh:195`), `<n>` the count in the
   manifest's `world_volumes:`.
3. Run `../migrations/run-migrations.sh`, which every restore needs for its
   grants and logins (`README.md`, Restore). The directories it is given
   decide where the window goes:
   - To retry, the new release's `MIGRATIONS_DIR` and `GRANTS_FILE`, once the
     cause of the failure is found and fixed. That run is the entry's step 3
     again, its checks included, and the window goes on from there. The
     `gangs` count taken before the first run still holds, since the restore
     put the table back to the stop.
   - To go back to the previous tag, the `MIGRATIONS_DIR` and `GRANTS_FILE`
     of the riftal-game commit that tag's plugins were built from. Its log
     must read `nothing pending` (`run-migrations.sh:299`); anything applied
     means the directory is not that release's, so stop there. Then start
     each instance on the previous tag. The database holds none of the run's
     migrations, so no migration entry's bar on older tags applies to it.
     That run applies the previous release's `grants.sql`, and its GRANTs
     give back what a newer file revoked from the builds it shipped with:
     riftal-game CI runs every statement of each plugin's SQL file as that
     plugin's login against the same tree's file (`lib/tests/mysql/grants.sh`,
     run by `.github/workflows/ci.yml:123` at `cea814f`). So no grants
     entry's bar applies either. A previous tag whose plugins were built from
     before riftal-game PR #454 (`cea814f`), a release with no `grants.sql`,
     is never a rollback, serial or by restore: see No rollback to a plugin
     build from before riftal-game PR #454, below.

### A migration that fails partway

`run-migrations.sh` stops at the first migration that errors and leaves it
unrecorded (`../migrations/README.md`, step 4). It does the same when a
migration applied but its `schema_migrations` row could not be written. The
log names either: `migration <id> failed` or `<id> applied but could not be
recorded as applied`, each followed by `applying grants for what did apply,
then stopping` (`run-migrations.sh:276`, `:290`, `:294`).

What ran before the failing statement stays: MySQL DDL commits implicitly and
is never rolled back. For 0010 that is `ALTER TABLE gangs ADD COLUMN founded`
(`0010_add_gang_founded_marker.sql:4`), so a retry fails on that line with a
duplicate column error and never reaches the backfill or the procedure. A
failure after its `DROP PROCEDURE IF EXISTS gangs_ledger_contribute` (`:16`)
also leaves no procedure at all, and 0015 drops the same procedure before it
recreates it (`0015_raise_gang_level_with_contribution.sql:9`).

Inside the window:

1. Start no instance. A partly applied migration matches no build.
2. Repair nothing by hand: no dropping the column, recreating the procedure,
   or writing the `schema_migrations` row. The failed run's log is the only
   record of what committed, and a hand repair is a second, unrecorded
   migration.
3. Restore the recorded set as in When a restore is a rollback, above, and
   take its retry path once the cause is fixed. No instance has admitted a
   player, so this loses nothing.
4. If the cause is not found and fixed inside the window, take the
   previous-tag path above. If neither path can finish, the server stays down
   and it is Nasir's call.

A partial apply found after the first admission is Nasir's call, like any
restore then.

## Audited migrations

Every migration in `riftal-game/lib/resources/sql/migrations/` from `0001` to
`0020_create_gang_vault_slots.sql` has been checked against the rule above, at
riftal-game `main` `205e6e1`. Coupled: 0010, 0014 and 0015, each with its
entry below. A migration numbered above 0020 is unaudited until it is listed
here.

Each check is the rule above: whether a build from before the migration's PR,
running against the migrated schema, fails or writes rows the schema treats
differently. A newer build against an unmigrated schema fails for nearly
every migration whose table or procedure it uses, which is why the rule
leaves that direction to the migrations-first order; a coupled entry names it
only to explain what the entry's procedure prevents. `grants.sql` has its own
audit, below.

Not coupled:

- 0001 to 0006 and 0008: each creates a table in the same riftal-game PR as
  the first plugin code that uses it (#46, #60, #112, #146, #148, #174; #148
  carries both 0005 and 0006), so no older build reads it.
- 0007: `cumulative_contribution_minor_units` is `NOT NULL DEFAULT 0`, so a
  gang an older build creates starts where any new gang starts.
- 0009: a gangs build from before PR #217 (`a113487`) raises
  `cumulative_contribution_minor_units` with a direct `UPDATE` and writes no
  ledger row. That increment still lands, and the table and procedure 0009
  creates are ones that build never touches.
- 0011: an economy build from before PR #264 (`9bfc4df`) moves a balance
  without setting the nullable `updated_by_instance`, so that row keeps naming
  an earlier writer. No plugin reads the column.
- 0012: a gangs build from before PR #344 (`ba16152`) never raises `level`.
  The level is a high-water mark of the cumulative total, so the next raise
  by a newer build catches it up, the same lag 0012 gives every existing gang.
- 0013: PR #422 (`835ea66`) changes no plugin code, and `accounts.username`
  has no unique key (`0001:5-12`), so the collation change merges no rows.
- 0016: an economy build from before PR #891 (`9a80ef1`) moves balances with
  no `economy_ledger` row. ADR 006 (riftal-pm `docs/decisions/006`,
  Consequences) accepts that window under the serial rollout and pins the
  balance snapshot to after it. The `grants.sql` from PR #923 closes that
  window: see its entry below.
- 0017: a gangs build from before PR #808 (`fec6736`) passes a levels list
  with no `contested_mine` marker, so its raises leave the flag `FALSE`. The
  next raise by a newer build sets it (`0017:22-28`), the same lag 0017 gives
  every gang already at the level, and nothing writes it back to `FALSE`.
- 0018: no plugin build calls `economy_balance_snapshot_take` or `_void`.
- 0019: a mines build from before PR #884 (`1105889`) never reads or clears
  the unstable ore columns. A position it leaves set holds a block its refill
  wrote, and the next reset claim on a newer build clears it
  (`mines/resources/sql/mines.sql:39`, `:49`).
- 0020: no gangs build from before PR #1022 (`7fa533e`) reads
  `gang_vault_slots` or calls `gangs_vault_deposit`. On such a build, an item
  already deposited stays in its slot row, out of reach until a build with
  `/gang vault` (PR #1124, `a09b00a`) runs again.

## Audited `grants.sql`

Every version of `riftal-game/lib/resources/sql/grants.sql`, from PR #454
(`cea814f`) through PR #1022 (`7fa533e`), its last change on riftal-game
`main` `205e6e1`, has been checked against the rule above. Coupled: PR #923's
REVOKE, with its entry below. A `grants.sql` change after `7fa533e` is
unaudited until it is listed here.

The audit covers plugin builds from riftal-game PR #454 (`cea814f`) onward,
the first release with a `grants.sql`. A tag whose plugins were built from
before PR #454 is never a rollback, serial or by restore: see No rollback to
a plugin build from before riftal-game PR #454, below.

Each check is whether a plugin build from PR #454 onward needs a privilege
that version revokes or never grants. A run that stops at a failed migration
applies grants too (`../migrations/run-migrations.sh:275-278`), but no
instance starts after one (A migration that fails partway, step 1).

Not coupled:

- PRs #264, #337, #344, #651, #675, #735, #884 and #1022 only add GRANTs, so
  an older build keeps every privilege it had.
- PR #647 (`cfe968b`) revokes `riftal_role_accounts`, the `accounts` write
  role, from the five plugin roles (`grants.sql:38`). No plugin build writes
  `accounts` through one of them: no plugin's `src/` constructs
  `AccountResolver` before PR #473 (`11d8997`), which moved the
  `accounts.resolve` upsert into the `accounts` plugin, whose login keeps the
  role.
- `mines` and `riots`: every version of `mines.sql` (PRs #112, #251, #884)
  and `riots.sql` (PRs #146, #935, #1051, #1112) assigns only columns the file
  grants UPDATE on, and deletes nothing.
- Every plugin build from PR #454 onward: riftal-game CI runs every
  statement of each plugin's SQL file as that plugin's login against the same
  tree's `grants.sql` (`lib/tests/mysql/grants.sh`, run on every pull request
  by `.github/workflows/ci.yml:123` at `cea814f`), and every later version
  except PRs #647 and #923 only adds GRANTs, so a build keeps every privilege
  its own release granted. PR #647 has its bullet above and PR #923 its entry
  below.

## 0010 and the gangs `mark_founded` build ship together

Migration: `riftal-game/lib/resources/sql/migrations/0010_add_gang_founded_marker.sql`.
Matching build: any `gangs` build carrying riftal-game PR #266 (merge commit
`67f6089`), which landed the migration and `gangs.mark_founded`
(`riftal-game/gangs/resources/sql/gangs.sql:28-31` at riftal-game `main`
`164184c`) in the same commit. Source:
riftal-game#247, ADR 004 Decision item 12.

What 0010 does:

- Adds `gangs.founded BOOLEAN NOT NULL DEFAULT FALSE`.
- Marks every gang already present as founded, once, printing the count as
  `founded_backfilled`.
- Recreates `gangs_ledger_contribute` so its `UPDATE` matches only a gang with
  `founded = TRUE`. Anything else reports `gang_gone`, and the contribution is
  refunded. Later redefinitions (`0015_raise_gang_level_with_contribution.sql`)
  keep that condition.

Why the two cannot be split:

- **Older build, migrated schema.** A `gangs` build from before PR #266 never
  calls `mark_founded`, so every gang it creates after 0010 is left at the
  column default, `founded = FALSE`. The database then refuses every
  contribution to that gang, and an instance on a build from riftal-game
  PR #724 (`aed36a6`) onward does not find it through `gangs.find_by_name`
  for a join. The other readers that filter on `founded = TRUE` refuse it the
  same way: `gangs_join` (`0012_add_gang_level_and_join.sql:40`),
  `gangs_vault_deposit` (`0020_create_gang_vault_slots.sql:64`) and
  `gangs.contested_mine_eligible` (`gangs/resources/sql/gangs.sql:165`).
  Nothing marks those rows later: the backfill ran once and 0010 is recorded
  as applied.
- **Newer build, unmigrated schema.** The build from PR #266 onward reads and
  writes `gangs.founded` (`mark_founded`, `delete_reservation`,
  `member.find_gang`, and from PR #724 `find_by_name`), which does not exist
  until 0010 runs, so gang creation and contributions fail.

So, for any release that takes a database from before 0010 to after it:

1. Stop every instance cleanly.
2. Back up as in The window's backup and restore, above, and record the set
   name. Restoring it is a rollback only until the first instance on the new
   tag admits a player; after that it is Nasir's call, never a rollback.
3. Count the rows in `gangs` with the command in Count `gangs` before a run
   that applies 0010, above, then run the migrations. The runner prints
   result sets without column names (`migrations/run-migrations.sh` calls
   `mysql -N -B`), so the log shows `applying 0010_add_gang_founded_marker.sql`
   followed by a bare number, the backfilled row count, never the label
   `founded_backfilled`. Confirm that number equals the count taken before the
   run, and that `schema_migrations` records `0010_add_gang_founded_marker.sql`.
4. Start every instance on an image tag that carries the matching build of
   every coupled migration and grants change the run applied: PR #266 for
   0010, and PR #675 for 0014, PR #712 for 0015 and PR #891 for PR #923's
   `grants.sql` when the run crosses them too (see below).
5. Rollback is an image tag that meets the same condition. Until the first
   instance on the new tag admits a player, it can also be the restore in
   When a restore is a rollback, above; after that, nothing else. No image
   tag older than PR #266 runs against a database with 0010 applied.

If gangs were created by an older build after 0010 was applied, they stay
unfounded. Marking them founded changes player data and is not a step of the
rollout; it needs Nasir's call.

## 0015 and the gangs build that passes `:levels` ship together

Migration: `riftal-game/lib/resources/sql/migrations/0015_raise_gang_level_with_contribution.sql`.
Matching build: any `gangs` build carrying riftal-game PR #712 (merge commit
`829565d`), which landed the migration and the 11-argument
`CALL gangs_ledger_contribute(..., :instance_id, :levels, @gangs_ledger_outcome)`
(`riftal-game/gangs/resources/sql/gangs.sql:75`) in the same commit. PR #712
descends from PR #266, so a tag carrying it also meets the 0010 condition.

What 0015 does: drops `gangs_ledger_contribute` and recreates it with an
`IN p_levels JSON` parameter before `OUT p_outcome` (`0015:22`), 11 parameters
where 0009 and 0010 declare 10, so it raises the gang level inside the
contribution's transaction. The `founded = TRUE` condition stays (`0015:40`).

Why the two cannot be split:

- **Older build, migrated schema.** A build from before PR #712 calls the
  procedure with 10 arguments, so every contribution CALL fails on the
  argument count.
- **Newer build, unmigrated schema.** A build from PR #712 onward calls it
  with 11, which the 0010 definition refuses the same way.

So, for any release that takes a database from before 0015 to after it:

1. Stop every instance cleanly.
2. Back up as in The window's backup and restore, above, and record the set
   name. Restoring it is a rollback only until the first instance on the new
   tag admits a player; after that it is Nasir's call, never a rollback.
3. Run the migrations and confirm `schema_migrations` records
   `0015_raise_gang_level_with_contribution.sql`.
4. Start every instance on an image tag whose `gangs` plugin carries PR #712,
   and the matching build of any other coupled migration or grants change the
   run applied.
5. Rollback is an image tag that meets the same condition. Until the first
   instance on the new tag admits a player, it can also be the restore in
   When a restore is a rollback, above; after that, nothing else. No image
   tag older than PR #712 runs against a database with 0015 applied.

## 0014 and the ranks build that holds a rank-up claim ship together

Migration: `riftal-game/lib/resources/sql/migrations/0014_add_player_ranks_claim.sql`.
Matching build: any `ranks` build carrying riftal-game PR #675 (merge commit
`0a1d21d`), which landed the migration and the claim queries `ranks.advance`,
`ranks.settle` and `ranks.revert`
(`riftal-game/ranks/resources/sql/ranks.sql:42-77` at riftal-game `main`
`164184c`) in the same commit.
Source: ADR 021 (riftal-pm#1029).

What 0014 does: adds six nullable claim columns to `player_ranks`, all set or
all `NULL` under a CHECK (`0014:15-20`). A held claim is a rank-up whose debit
has not answered: the block counter is zeroed and `current_rank` has not
moved, because `current_rank` holds only a paid rank (`0014:2-3`).

Why the two cannot be split:

- **Older build, migrated schema.** A `ranks` build from riftal-game PR #651
  (`e5deb31`) up to before PR #675 advances on `current_rank = :from_rank AND
  blocks_mined_since_rankup = :mined` alone (`ranks.sql:40-41` at
  `0a1d21d^`) and never reads the claim columns. On a row holding a claim it
  moves `current_rank` anyway, debiting for a rank the claim may already have
  paid for, and it never settles, reverts or takes over that claim. When a
  build from PR #693 (`59e68bf`) onward takes the claim after its lease, its
  revert adds `claim_mined` to the counter of the rank the older build moved
  to. A `ranks` build from before PR #651 has no rank-up.
- **Newer build, unmigrated schema.** A build from PR #675 onward reads and
  writes the claim columns (`ranks.progress`, `ranks.advance`), which do not
  exist until 0014 runs, so every rank-up fails.

So, for any release that takes a database from before 0014 to after it:

1. Stop every instance cleanly.
2. Back up as in The window's backup and restore, above, and record the set
   name. Restoring it is a rollback only until the first instance on the new
   tag admits a player; after that it is Nasir's call, never a rollback.
3. Run the migrations and confirm `schema_migrations` records
   `0014_add_player_ranks_claim.sql`.
4. Start every instance on an image tag whose `ranks` plugin carries PR #675,
   and the matching build of any other coupled migration or grants change the
   run applied.
5. Rollback is an image tag that meets the same condition. Until the first
   instance on the new tag admits a player, it can also be the restore in
   When a restore is a rollback, above; after that, nothing else. No image
   tag older than PR #675 runs against a database with 0014 applied.

## PR #923's `grants.sql` and the economy build that calls the ledger procedures ship together

Grants change: riftal-game PR #923 (merge commit `b6860bb`), in
`riftal-game/lib/resources/sql/grants.sql`. Matching build: any `economy`
build carrying riftal-game PR #891 (merge commit `9a80ef1`), which moved every
balance change into `CALL economy_ledger_credit` and `CALL
economy_ledger_debit` (`economy/resources/sql/economy.sql:35`, `:47` at
`9a80ef1`). PR #891 is an ancestor of PR #923. Related:
`grants-revoke-check.sh` (riftal-infra#1187, closing riftal-infra#944), which
belongs in `/deploy-release` stage 1 and refuses a `grants.sql` REVOKE that is
new against any tag a container or an instance definition still names.

What PR #923 does: leaves `riftal_role_economy` only `UPDATE (account_id)` on
`balances`, for the ensure upsert, and revokes `UPDATE (balance_minor_units,
updated_by_instance)` from it (`grants.sql:52-54` at `7fa533e`). Every run
from then on applies that REVOKE.

Why the two cannot be split:

- **Older build, newer grants.** An `economy` build from before PR #891
  moves a balance with a direct `UPDATE balances SET balance_minor_units`
  (`economy.sql:30`, `:43` at `9a80ef1^`), so every credit and debit fails
  with ERROR 1143, reproduced on mysql:8 8.4.11: the statement succeeds as
  the economy login under the file at `b6860bb^` and is denied on
  `balance_minor_units` once the file at `7fa533e` is applied over it.
- **Newer build, older grants.** Not a constraint: a build from PR #891
  onward needs EXECUTE on the two ledger procedures, which every file from
  PR #735 (`58888cf`) grants.

So, for any release whose run applies a `grants.sql` from PR #923 onward to a
database whose last run applied one from before it:

1. Stop every instance cleanly.
   Then, before stage 1 applies the grants, run `grants-revoke-check.sh` with
   the new file, the release tag and `<tag>=<file>` for each older tag still
   in use (`README.md`, Grants REVOKE check). The check counts a stopped
   container of an older tag and an instance definition naming one as that tag
   in use, so it refuses the run until, on each machine that runs instances,
   every stopped container of the older tag is removed (its volumes stay) and
   every `instances/<id>/image` names the release tag. Run it once per
   runtime and per machine, with `INSTANCE_IMAGE` the exact reference that
   runtime reports; a pass on one covers no other.
2. Back up as in The window's backup and restore, above, and record the set
   name. Restoring it is a rollback only until the first instance on the new
   tag admits a player; after that it is Nasir's call, never a rollback.
3. Run the migrations. The log reads `applying grants from <file>`
   (`run-migrations.sh:267`) with no `failed` after it. Confirm the REVOKE
   held: the `balances` line of

   ```sh
   timeout 120 wslc run --rm --network riftal-dev \
     -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
     mysql:8 mysql --host=mysql --user=root -N -B \
     -e 'SHOW GRANTS FOR riftal_role_economy'
   ```

   grants UPDATE on `account_id` alone.
4. Start every instance on an image tag whose `economy` plugin carries PR
   #891, and the matching build of any other coupled migration or grants
   change the run applied.
5. Rollback is an image tag that meets the same condition. Until the first
   instance on the new tag admits a player, it can also be the restore in
   When a restore is a rollback, above; after that, nothing else. No
   `economy` build older than PR #891 runs against a database whose grants
   came from PR #923 onward.

## No rollback to a plugin build from before riftal-game PR #454

An image tag whose plugins were built from before riftal-game PR #454
(`cea814f`) is never a rollback target, serial or by restore. The bar is
permanent.

What the release that first ships `grants.sql` leaves: its run creates the
file's roles and grants and provisions one login per
`RIFTAL_DB_PASSWORD_<NAME>`, the six of ADR 008 item 1 (`accounts`,
`economy`, `gangs`, `mines`, `ranks`, `riots`;
`../migrations/run-migrations.sh:304-331`). Neither rollback undoes any of
it:

- Serial: nothing runs against the server, so every role, grant, login and
  password stays as that run left it.
- By restore onto the same server: `restore.sh` drops and recreates only the
  database (`restore.sh:159-161`). Roles, logins and their grants live in the
  `mysql` schema and stay, procedure grants included: on mysql:8 8.4.11,
  `mysql.tables_priv`, `columns_priv` and `procs_priv` held 12, 30 and 6 rows
  for the schema before the drop and the same after it. The pre-#454
  release's run changes none of it: given that release's absent
  `GRANTS_FILE`, or any `RIFTAL_DB_PASSWORD_*`, it refuses before connecting
  (`run-migrations.sh:83-86`); given neither, it applies no grants (`:268`)
  and provisions no login.
- By restore onto a fresh server: no role or login exists.

Which login a pre-#454 build connects as: its config's `database.username`.
Each plugin's `resources/config.yml` has named its own login, with
`password: ""`, since the plugin's scaffold: `economy` (PR #60, `f55afcc`),
`mines` (PR #121, `48f1e8d`), `riots` (PR #146, `cca42db`), `gangs` (PR #148,
`2ba7d0f`), `ranks` (PR #174, `bd8f121`). None connects as `accounts`: that
plugin starts at PR #473 (`11d8997`). The password comes from
`database.password` alone: `DatabaseSettings::fromConfig` takes no
environment before PR #454
(`lib/src/RiftalGames/Lib/Database/DatabaseSettings.php:38` at `cea814f^`).

Why no pre-#454 build runs under what either rollback leaves:

- With the shipped empty password, a login the window provisioned refuses
  it, `ERROR 1045 (28000): Access denied for user 'economy'@'localhost'
  (using password: NO)` on mysql:8 8.4.11, and on a fresh server the login
  does not exist. Every database plugin fails to enable.
- Giving that build a password means writing it into its `config.yml` under
  `/data/plugin_data`, on the world volume every backup set tars, which ADR
  008 item 5 forbids (riftal-pm `docs/decisions/008`). Pointing it at root
  instead is the exposure that ADR's Context describes. Neither is a rollback
  step.
- Authenticated anyway, `gangs` and `economy` fail on the window's grants. As
  `gangs`, a build from before PR #217 (`a113487`) raises the gang total
  with a direct `UPDATE`, which every `grants.sql` version denies: `ERROR
  1143 (42000) ... for column 'cumulative_contribution_minor_units'`. As
  `economy`, a pre-#454 credit's `UPDATE balances SET balance_minor_units`
  gets ERROR 1143 under any file from PR #923 on. Both reproduced on mysql:8
  8.4.11 under the file at `7fa533e`. Every pre-#454 `gangs` build is also
  older than PR #712, and every `ranks` build older than PR #675, so the 0015
  and 0014 entries bar them wherever the run applied those migrations. Only `mines` and `riots` would pass on privileges (Audited
  `grants.sql`), and they still fail to authenticate.

The bar is not lifted for `mines` and `riots`, because the only way past
authentication is a credential on the world volume. It costs no reachable
rollback: no production deploy predates PR #454, so a production previous
tag is a pre-#454 one only if such a tag is first deployed new, which fails
on authentication the same way. A window
whose previous tag would be one has only the retry path in When a restore is
a rollback, step 3; if that cannot finish, the server stays down and it is
Nasir's call.

## `riftal_dev` and the wipe's `RIFTAL_DEV_ENV=1` belong to the dev stack

No alpha, production or rig stack names its database `riftal_dev`, and no
alpha, production or rig wipe run is given `RIFTAL_DEV_ENV=1`. Both are
reserved for the shared dev stack, `../images/compose.yaml`
(`../images/README.md`, Reserved for the dev stack). The one other place
`riftal_dev` may appear is riftal-infra#1110's selftest, which creates it in
throwaway `mysql:8` containers as a fixture for the script, not a stack the
wipe serves.

The reservation is a standing rule. It exists for the wipe's dev path, which
riftal-infra#1110 is to build to the steward rulings on riftal-pm#1312 and
riftal-pm#1314. That path takes two keys, both required, each matched
exactly: `RIFTAL_DEV_ENV=1` in the wipe's own environment, and a
`MYSQL_DATABASE` of `riftal_dev` present on the target server. The two keys
gate every wipe that clears a level with no build, default or non-default.
With both, such a level is cleared: afterwards core generates a default level
fresh on the next boot, and a non-default level is left absent. Any other
combination refuses the wipe, `RIFTAL_DEV_ENV=1` against another database
included. A stack outside the shared dev stack carrying either value is one
key away from the dev path, and both would make the wipe treat it as dev. The
ruling reverses if one does.
