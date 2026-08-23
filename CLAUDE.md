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
- Instances are containers from one image. A split is another container from the same tag with a different `instance_id` and world list, not a provisioned host. This is why the container decision was made, so do not let the runbook drift back toward host provisioning.

## Layout

| Path | Contents |
|---|---|
| `proxy/` | WaterdogPE `config.yml`, server list, forced hosts, resource pack settings |
| `instances/` | One definition per running instance: which worlds it serves, its `instance_id`, its resources, its `server.properties` and `pocketmine.yml` overrides |
| `migrations/` | Production migration runner and applied-state records. Migration files themselves are authored in `riftal-game/lib/resources/sql/migrations/`. |
| `deploy/` | Rollout and rollback scripts, backup jobs, health checks |
| `images/` | Dockerfiles we own: the WaterdogPE proxy image, and any wrapper around the core image. Plus the local dev stack composition. |

## Platform facts

Verified, do not re-derive:

- **Proxy is WaterdogPE.** Requires **Java 17 or newer**. PocketMine-MP is an officially supported downstream.
- **Downstreams run offline mode.** The proxy performs Xbox authentication and forwards XUID and IP to the downstream in custom login packet fields.
- **Required on every PMMP downstream:**
  - `server.properties`: `xbox-auth=false`
  - `pocketmine.yml`: `player.verify-xuid: false`

  The second is needed because the downstream sees the player as unauthenticated, so PMMP's XUID check cannot match. Missing either one produces login failures that look like a protocol bug and are not.
- **Downstreams must not be reachable from the internet.** They are in offline mode. The proxy is the only public entry point. Under containers this means instance ports are published to the proxy's container network only and never to a host interface. See the Containers section below.
- **Database is MySQL 8**, shared by every instance. It runs as a container, with its data directory on a named volume.
- **Everything runs in containers**, dev and production. Base image for everything we build is `ubuntu:24.04`. The host OS is a container runtime and nothing more. Decided 2026-08-23, superseding the earlier bare-host decision. See `../docs/decision-log.md`.
- **Bedrock is UDP.** RakNet on `19132/udp`. Any port publishing, network mode, or firewall change has to be checked against UDP specifically, because a TCP-only test will pass while every player fails to connect.

## Containers

This repo owns the container story end to end. It is the newest part of the platform and the least battle-tested, so the rules are explicit.

**Images are built from Dockerfiles in git, and deployed by immutable tag.** Never a `latest` tag in production, never a container patched in place, never an image built on the host it runs on. If you cannot name the tag a thing is running, you cannot roll it back.

**The container filesystem is disposable. Worlds are not.** Everything that must survive a container being replaced lives on a named volume or a bind mount:

| Data | Why it must be a volume |
|---|---|
| World directories | The whole point. A world lost to a container replacement is unrecoverable player time. |
| MySQL data directory | Shared authoritative state for every instance. |
| Logs | Needed after the container that produced them is gone, which is exactly when an incident is being investigated. |
| Instance config | Comes from `instances/` in this repo, mounted in. The image stays generic, the config makes it a specific instance. |

One image serves every instance. What makes a container `mine-h` rather than `plots-1` is its mounted config and its `instance_id`, never a separately built image. Per-instance images would put us back to matching versions by hand, which is what containers were adopted to stop.

**Downstream instances stay unreachable from the internet.** This does not weaken under containers, it gets easier to get wrong. Instance ports are published to the proxy's container network only, never bound to a host interface. The proxy is the sole public entry point. Publishing an instance port to `0.0.0.0` for convenience during debugging exposes an offline-mode server, so do not do it, and if you must, close it in the same session.

**A deploy is a tag change and a rollback is the previous tag.** This is a better rollback than a file copy and it should be exercised, not just documented.

**Do not assume `wslc`.** Local development uses it because it is what Nasir's Windows machine has. Production uses a standard container runtime. Every Dockerfile and compose definition must run under both, which in practice means standard OCI features and nothing exotic.

## Rollout rules

- Order is always: database migrations, then instances one at a time, then the proxy last. The proxy goes last because it is the gate that admits updated clients.
- Announce in Discord before any window that takes the server down. During a Bedrock protocol update, announce before work starts, not when it finishes.
- Every rollout has a rollback path written down before it begins. If a step has no rollback, say so out loud and get Nasir's call before running it.
- Deploy by image tag, one instance at a time. The previous tag is the rollback and it stays available until the new one has survived a peak.
- Back up the database before any migration. A backup that has never been restored is not a backup, so test a restore on a schedule.

## Skills

- `/dev-stack` to stand up or tear down the local container stack
- `/add-instance` to split a world onto its own instance
- `/deploy-release` to roll out a new build

## Communication style

Direct and concise. Short points, minimal words.
Never use em dashes.
Answer what was asked. No unrequested analysis.
When you need a decision, ask one clear question with options.
