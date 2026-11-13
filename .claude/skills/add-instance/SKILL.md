---
name: add-instance
description: World-split runbook. Provision a new server instance, move a world onto it, register it with the proxy, point it at the shared database, and verify. Use when a world needs its own instance.
when_to_use: A world is outgrowing its current instance, a new world is being added, or the split procedure is being rehearsed on staging.
argument-hint: [world-name]
---

# Add an instance

The world-split. This is the core scaling operation on RiftalGames. Rehearse it on staging before running it in production, and run it inside an announced window.

## Preconditions

- [ ] Which world is moving, and which instance currently serves it.
- [ ] A backup of the shared database, taken and verified restorable.
- [ ] A backup of the world directory.
- [ ] Discord announcement posted for the window.
- [ ] An `instance_id` chosen for the new instance. Short, stable, never reused: `mine-h`, `plots-1`, `contested`.

## 1. Provision

Instances are containers from one shared image. There is no host to build and no software to install. What makes this container a specific instance is its mounted config and its `instance_id`, never a separately built image.

- [ ] Create `instances/<instance_id>/` in this repo holding its `server.properties`, `pocketmine.yml`, plugin configs, and world list. The container is disposable, the definition in git is not. This is the actual provisioning step.
- [ ] Run the core image **at the same tag every other instance runs**. Mixed core versions behind one proxy is a protocol mismatch waiting to happen, and with containers there is no excuse for it, because the tag is right there.
- [ ] Mount the plugin phars for this instance's worlds. An instance loads only the plugins it needs, but the shared library version must match everywhere, because they share a schema.
- [ ] Mount the world directory on a volume. Never in the container layer. A world in a container layer is a world that a redeploy destroys.
- [ ] Mount that volume read-only in `backup` too, as `/worlds/<volume>` beside the others in `images/compose.yaml`. `backup.sh` captures whatever it finds under `/worlds`, so a volume left off that list is never backed up (ADR 015).
- [ ] Mount `riftal-capture:/capture:ro` in the new instance. `RiftalCapture` reads the backup's request there and stages its answer on the instance's own volume (ADR 015 item 2).
- [ ] Load `RiftalCapture` in the new instance's roster. It loads from the top of `./plugins`, so the `./plugins:/plugins` mount carries it. A backup run against an instance without it fails after `CAPTURE_ACK_TIMEOUT_SECONDS`.
- [ ] Join it to the stack network.
- [ ] Downstream config, both required:
  - `server.properties`: `xbox-auth=false`
  - `pocketmine.yml`: `player.verify-xuid: false`
- [ ] **Do not publish the instance port to a host interface.** It is reachable on the container network by the proxy and by nothing else. The instance is in offline mode and must never be publicly reachable. Under containers this is a publish decision rather than a firewall rule, which makes it easier to get wrong and easier to fix.

If this step feels like it is taking real time, something has drifted. Adding an instance should be a config directory plus a container run. That was the reason for the container decision.

## 2. Move the world

- [ ] Stop writes to the world on the source instance. Either stop the instance or unload the world.
- [ ] Copy the world directory to the new instance. Verify the copy: file count and total size match.
- [ ] Set the new instance's default world and its world list.
- [ ] **Freeze the source copy.** Rename it, do not delete it. It is the rollback. It gets deleted at the end, after verification, not before.

## 3. Register with the proxy

- [ ] Add the downstream to `proxy/config.yml` under the server list, addressed by **container name** on the stack network, not by IP. Container IPs change on restart.
- [ ] Update any forced host or routing rule that pointed at the old instance for this world.
- [ ] Update whatever the game plugins use to route a player to a world, so a transfer targets the new instance. This is config in this repo, not a code change.
- [ ] Reload the proxy.

## 4. Point at shared state

- [ ] Same MySQL credentials, same database, as every other instance. There is no per-instance database.
- [ ] Set `instance_id` in the instance config to the id chosen above. Rows representing this world's state will carry it.
- [ ] Confirm the schema is current: the instance must not boot against a database with pending migrations. Run migrations first if any are outstanding.

## 5. Verify

Do not skip any of these. Each one catches a different failure.

- [ ] The instance boots clean and every plugin enables.
- [ ] It is running the same image tag as every other instance. Check, do not assume.
- [ ] Restart the container and confirm the world survived. This proves the world is on a volume and not in the container layer.
- [ ] A player joins through the proxy and lands in the moved world.
- [ ] The XUID arrived: the player's identity on the new instance matches their identity elsewhere. If ranks or balances look wrong or empty, the xuid or auth config is wrong.
- [ ] **Cross-instance transfer** in both directions: walk or command from another instance into this world and back.
- [ ] **Shared state is coherent**: check a balance and a rank on the new instance, change it on another instance, confirm the change is visible here.
- [ ] An auction listing created on another instance is visible and purchasable from this one.
- [ ] World state writes carry the right `instance_id` in the database.
- [ ] Latency and tick rate on the new instance are healthy under a real join.

## 6. Cut over and clean up

- [ ] Remove the world from the source instance's world list.
- [ ] Confirm no route anywhere still points at the old location.
- [ ] Watch for one full peak period before deleting the frozen source copy.
- [ ] Commit the `instances/` definition and the proxy config change together, in one commit.
- [ ] Announce completion in Discord.
- [ ] Add a dated entry to `../docs/decision-log.md` recording what moved, why, and anything the runbook got wrong. Fix the runbook in the same commit.

## Rollback

At any point before cut-over: point the proxy back at the source instance, unfreeze the source world copy, reload the proxy. State is in the shared database and was never moved, so nothing is lost.

The new container can simply be stopped and removed. It holds no state that matters, which is the property to preserve.

After cut-over, rollback means moving the world back the same way. The window for a cheap rollback closes when players start writing to the new copy, so verify before you cut over, not after.

To restore a backup set onto the new instance's volume, stop the instance first. A restore under a running instance is overwritten by its next save, so `restore.sh` refuses any volume whose `server.lock` is held (ADR 015 item 7).
