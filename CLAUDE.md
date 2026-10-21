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
| `instances/` | One definition per running instance: which worlds it serves, its `instance_id`, its resources, its `server.properties` and `pocketmine.yml` overrides. `instances/<instance_id>/image` holds one line, `<INSTANCE_IMAGE>:<tag>`, the record of the image tag that instance runs (`deploy/README.md`). |
| `migrations/` | Production migration runner and applied-state records. Migration files themselves are authored in `riftal-game/lib/resources/sql/migrations/`. |
| `deploy/` | Rollout and rollback scripts, backup jobs, health checks |
| `images/` | The local dev stack: `compose.yaml` (`mysql`, core instances `instance` and `instance-b` on the `local-pocketmine-mp` image, and `backup`), `.env.example`, and `plugins/`, the dev-only plugins and start scripts bind-mounted into the instances, with their self-tests. The core image is built in `pmmp-core`; `images/release/Dockerfile` adds the plugin phars to it and `deploy/release-image.sh` tags the result. `core-image.sha` pins the pmmp-core sha whose `local-pocketmine-mp:<sha>` tag every CI check that boots the core image runs, through `core-image.sh`; a new pin is a normal PR. |
| `designer/` | The designer toolchain. `designer/stack/` is the single-container designer stack with its own `compose.yaml`; the rest of `designer/` is the Python toolkit and its MCP server. |

## Platform facts

Verified, do not re-derive:

- **Proxy is WaterdogPE.** Requires **Java 17 or newer**. PocketMine-MP is an officially supported downstream. No proxy runs yet: it arrives when the first world splits off (`../docs/decision-log.md`, 2026-09-12).
- **Downstreams behind the proxy run offline mode.** The proxy performs Xbox authentication. It does not give the downstream a usable XUID: WaterdogPE's `use_login_extras` is off by default, and with it on, this fork drops the `Waterdog_*` login fields before `PlayerInfo::getExtraData()` is built, so no plugin can read them. A proxied login arrives with an empty XUID (`../pmmp-core/docs/player-identity-consequences-for-m1.md`).
- **Required on every PMMP downstream behind the proxy:**
  - `server.properties`: `xbox-auth=false`
  - `pocketmine.yml`: `player.verify-xuid: false`

  The second is needed because a proxied login arrives self-signed with an empty XUID, so PMMP's XUID check cannot match. Missing either one behind the proxy produces login failures that look like a protocol bug and are not. On an instance that Xbox-signed clients reach directly, leave `player.verify-xuid` at its default: their XUID is real, and the check stops impersonation.
- **Downstreams must never be reachable from the internet.** An offline-mode instance the internet can reach lets anyone claim any identity (`../pmmp-core/docs/player-identity-consequences-for-m1.md`). With a proxy in front, instance ports are published to the proxy's container network only and the proxy is the sole public entry point. Without one, an instance is published on a host interface: `images/compose.yaml` defaults to `127.0.0.1`. A wider bind is a deliberate, reversible act that never faces the internet, and the root `../CLAUDE.md` limits which addresses an `xbox-auth=false` instance may use (riftal-pm#491). See the Containers section below.
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

**Downstream instances stay unreachable from the internet.** This does not weaken under containers, it gets easier to get wrong. With a proxy in front, instance ports are published to the proxy's container network only, never bound to a host interface, and the proxy is the sole public entry point. Before a proxy, the host publish defaults to `127.0.0.1` and never faces the internet. Widening it for debugging convenience exposes an offline-mode server, so do not do it; any wider bind follows the root `../CLAUDE.md` rule for `xbox-auth=false` instances.

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
