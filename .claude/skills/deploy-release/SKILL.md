---
name: deploy-release
description: Roll out a new build across the database, the instances, and the proxy in the correct order, with rollback steps for each stage. Use for any production deployment, including protocol updates.
when_to_use: Shipping a plugin release, a core protocol update, or a schema migration to production.
argument-hint: [version]
---

# Deploy a release

## Order

Fixed, and it is not negotiable:

1. **Database migrations**
2. **Instances**, one at a time
3. **Proxy**, last

The proxy goes last because it is the gate that admits clients. Opening the gate before the downstreams can serve what comes through it turns a maintenance window into an incident. On a protocol update this matters most: the proxy is what decides whether an updated client is allowed in at all.

## Before anything

- [ ] Know exactly what is shipping: core tag, plugin versions, migration numbers. Write it down.
- [ ] Confirm `pmmp-core` passed its boot test and `riftal-game` passed `/test-server`. Deployment does not discover bugs, it ships verified builds.
- [ ] Every instance will run the same core tag and the same shared library version when this finishes. Mixed library versions against one schema is a data bug.
- [ ] Database backup taken. Confirm the file exists and its size is plausible.
- [ ] Announce in Discord: what is changing, when the window starts, how long it should take. For a protocol update, announce before work begins, not at rollout.
- [ ] Rollback path written down for every stage below, including which backup restores what.

## Stage 1: Database migrations

- [ ] Take the backup if not already taken.
- [ ] Review pending migrations. Confirm each is additive. A migration that drops or renames a column while old instances are still running will take them down mid-rollout.
- [ ] Apply migrations. The runner takes a MySQL named lock so simultaneous boots cannot race.
- [ ] Verify `schema_migrations` lists everything expected and nothing unexpected.

**Rollback:** additive migrations need no rollback, leave them. For a destructive migration, restore from the backup, which means the whole window restarts. This is exactly why migrations are additive.

## Stage 2: Instances, one at a time

For each instance:

- [ ] Drain it. Stop routing new players to it at the proxy and let the current ones leave or transfer.
- [ ] Stop it cleanly. A hard kill risks unsaved world chunks.
- [ ] Deploy the new core build and plugin phars.
- [ ] Start it. Confirm it reaches "Done", every plugin enables, and no schema errors appear.
- [ ] Smoke it: join directly, confirm a database read and write round-trips.
- [ ] Return it to rotation.
- [ ] Watch it for a few minutes before moving to the next instance.

Never do all instances at once. Serial rollout means the first failure costs one instance, not the server.

**Rollback:** stop the instance, redeploy the previous core tag and plugin phars, start it. The database is shared and already migrated, which is safe because the migrations were additive.

## Stage 3: Proxy

- [ ] Update WaterdogPE if the release includes a proxy change or a protocol update. Java 17 or newer required.
- [ ] Update `proxy/config.yml` if the instance list or routing changed.
- [ ] Restart or reload the proxy. A restart disconnects everyone, so do it inside the window, not after announcing completion.
- [ ] Verify: join through the proxy on the target client version, land in the right world, transfer between two instances, confirm identity and balance are correct.

**Rollback:** restore the previous proxy jar and `config.yml`, restart. If the release was a protocol update, rolling the proxy back also means rolling every instance back, because a proxy on the old protocol cannot serve clients that already auto-updated. Decide that before starting, not during.

## After

- [ ] Announce completion in Discord, naming the version and, for a protocol update, the Bedrock version now supported.
- [ ] Watch logs and player reports through the next peak.
- [ ] Tag the deployed state in this repo so the running configuration is reproducible.
- [ ] Add a dated entry to `../docs/decision-log.md`: what shipped, actual window length, and anything that went wrong.

## Rules

One release at a time. Never overlap a protocol update with a gameplay release. When both are ready, ship the protocol update alone, verify it through a peak, then ship the gameplay release. Untangling which of two simultaneous changes broke something costs more than the extra window.
