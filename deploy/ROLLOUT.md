# Rollout notes

Ordering constraints that the fixed rollout order in `../CLAUDE.md`
(migrations, then instances one at a time, then the proxy) does not cover on
its own. Read this before every `/deploy-release` and before any manual
migration run against a database that instances are using. Newest constraints
go at the end; an entry stays as long as a database or an image tag it
describes can still be met.

## The general rule: a migration whose effect needs a matching plugin build

Most migrations are additive and safe under the serial rollout: an instance on
the previous image tag keeps working against the migrated schema, so instances
can be replaced one at a time and rolled back to the previous tag.

A migration is **coupled** when that is not true: when an instance on an older
plugin build, running against the migrated schema, writes rows the schema now
treats differently, or when the newer build cannot run against the unmigrated
schema. For a coupled migration:

- The migration and the plugin build that matches it reach every instance
  together. No instance runs the older build against a schema with the
  migration applied, and no instance runs the newer build against a schema
  without it.
- Since one image serves every instance, that means stopping every instance
  cleanly before the migration runs, then starting each on the new image tag.
  The serial, one-at-a-time replacement does not apply to that window: the
  window is a full stop.
- The previous image tag is not a rollback target once the migration has
  applied. Rollback is either an image tag that already carries the matching
  build, or a restore of the backup taken before the migration, which restarts
  the window.
- Write the coupled pair into the release's "what is shipping" list and into
  its rollback path before the window opens, naming the migration number and
  the plugin change.
- Whoever lands a coupled migration in `riftal-game` files an `owner:infra`
  issue to add its entry here, the same way riftal-infra#1015 added the first.

## 0010 and the gangs `mark_founded` build ship together

Migration: `riftal-game/lib/resources/sql/migrations/0010_add_gang_founded_marker.sql`.
Matching build: any `gangs` build carrying riftal-game PR #266 (merge commit
`67f6089`), which landed the migration and `gangs.mark_founded`
(`riftal-game/gangs/resources/sql/gangs.sql:28-31`) in the same commit. Source:
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
  for a join.
  Nothing marks those rows later: the backfill ran once and 0010 is recorded
  as applied.
- **Newer build, unmigrated schema.** The build from PR #266 onward reads and
  writes `gangs.founded` (`mark_founded`, `delete_reservation`,
  `member.find_gang`, and from PR #724 `find_by_name`), which does not exist
  until 0010 runs, so gang creation and contributions fail.

So, for any release that takes a database from before 0010 to after it:

1. Back up the database.
2. Stop every instance cleanly.
3. Count the rows in `gangs`, then run the migrations. The runner prints
   result sets without column names (`migrations/run-migrations.sh` calls
   `mysql -N -B`), so the log shows `applying 0010_add_gang_founded_marker.sql`
   followed by a bare number, the backfilled row count, never the label
   `founded_backfilled`. Confirm that number equals the count taken before the
   run, and that `schema_migrations` records `0010_add_gang_founded_marker.sql`.
4. Start every instance on an image tag whose `gangs` plugin includes PR #266.
5. Rollback is an image tag that also includes PR #266, or the step 1 backup.
   No image tag older than PR #266 runs against this database again.

If gangs were created by an older build after 0010 was applied, they stay
unfounded. Marking them founded changes player data and is not a step of the
rollout; it needs Nasir's call.
