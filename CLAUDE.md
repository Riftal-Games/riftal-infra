# riftal-infra

This repo owns everything between the code and the players. The WaterdogPE proxy, the server instances and how they are laid out, the shared database, migrations, backups, and every rollout. If a player cannot connect, the answer starts here.

It owns no gameplay behavior and no protocol internals. Those are `riftal-game` and `pmmp-core`.

## The instance-split move

Every world can be split onto its own server instance as population grows. That split is the core scaling operation of this project, and it must always stay a documented, tested procedure, not something improvised under load.

Concretely:

- The runbook is `/add-instance` and it stays current. When the topology changes, the runbook changes in the same commit.
- It gets rehearsed on a staging instance before it is needed in production. A runbook that has never been executed is a guess.
- Every system in `riftal-game` is built assuming the split can happen at any time, so infra never has to ask for a code change to perform one.
- One shared database across all instances. There is no per-instance database, ever. That is what makes a split a move of a world rather than a migration of state.

## Layout

| Path | Contents |
|---|---|
| `proxy/` | WaterdogPE `config.yml`, server list, forced hosts, resource pack settings |
| `instances/` | One definition per running instance: which worlds it serves, its `instance_id`, its resources, its `server.properties` and `pocketmine.yml` overrides |
| `migrations/` | Production migration runner and applied-state records. Migration files themselves are authored in `riftal-game/lib/resources/sql/migrations/`. |
| `deploy/` | Rollout and rollback scripts, backup jobs, health checks |

## Platform facts

Verified, do not re-derive:

- **Proxy is WaterdogPE.** Requires **Java 17 or newer**. PocketMine-MP is an officially supported downstream.
- **Downstreams run offline mode.** The proxy performs Xbox authentication and forwards XUID and IP to the downstream in custom login packet fields.
- **Required on every PMMP downstream:**
  - `server.properties`: `xbox-auth=false`
  - `pocketmine.yml`: `player.verify-xuid: false`

  The second is needed because the downstream sees the player as unauthenticated, so PMMP's XUID check cannot match. Missing either one produces login failures that look like a protocol bug and are not.
- **Downstreams must not be reachable from the internet.** They are in offline mode. The proxy is the only public entry point. Firewall the instance ports to the proxy host.
- **Database is MySQL 8**, shared by every instance.
- **Hosts are Ubuntu 24.04**, dev and production.

## Rollout rules

- Order is always: database migrations, then instances one at a time, then the proxy last. The proxy goes last because it is the gate that admits updated clients.
- Announce in Discord before any window that takes the server down. During a Bedrock protocol update, announce before work starts, not when it finishes.
- Every rollout has a rollback path written down before it begins. If a step has no rollback, say so out loud and get Nasir's call before running it.
- Back up the database before any migration. A backup that has never been restored is not a backup, so test a restore on a schedule.

## Skills

- `/add-instance` to split a world onto its own instance
- `/deploy-release` to roll out a new build

## Communication style

Direct and concise. Short points, minimal words.
Never use em dashes.
Answer what was asked. No unrequested analysis.
When you need a decision, ask one clear question with options.
