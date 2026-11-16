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
- [ ] A backup of the shared database, taken and verified restorable. A fresh database has nothing to back up: skip this, and the runner pass in section 4, with `RIFTAL_DB_PASSWORD_BACKUP` among its passwords, provisions the `backup` login and its `EXECUTE` grant on the capture fence procedures. A login provisioned without `grants.sql` cannot raise the fence, and `deploy/backup.sh` stops before the dump (`deploy/README.md`).
- [ ] A backup of the world directory.
- [ ] Discord announcement posted for the window.
- [ ] An `instance_id` chosen for the new instance. Short, stable, never reused: `mine-h`, `plots-1`, `contested`.

## 1. Provision

Instances are containers from one shared image. There is no host to build and no software to install. What makes this container a specific instance is its mounted config and its `instance_id`, never a separately built image.

- [ ] Create `instances/<instance_id>/` in this repo holding exactly two files: `image`, one line `<INSTANCE_IMAGE>:<tag>`, and `instance.env`, which carries `RIFTAL_LEVEL_ZONES` (the zone list) and `POCKETMINE_ARGS` (with exactly one `--level-name=<zone>`). No other file, `server.properties` and `pocketmine.yml` included, belongs in the definition. The container is disposable, the definition in git is not. This is the actual provisioning step.
- [ ] Run the core image **at the same tag every other instance runs**. Mixed core versions behind one proxy is a protocol mismatch waiting to happen, and with containers there is no excuse for it, because the tag is right there.
- [ ] Run it with `images/compose.yaml`'s `instance` policies: `restart: on-failure` (`--restart on-failure` on docker; no retry cap, because Docker counts `on-failure:<N>` over the container's whole life), the command starting with `bash /plugins/restart/boot-gate.sh` so a bad deploy cannot restart forever, and the RakNet healthcheck `php /plugins/restart/raknet-ping.php` with interval 30s, timeout 10s, retries 3 and start period 180s. On wslc the healthcheck flags exist but no restart flag does, so that instance does not come back after a crash by itself.
- [ ] Mount the plugin phars for this instance's worlds. An instance loads only the plugins it needs, but the shared library version must match everywhere, because they share a schema.
- [ ] Mount the world directory on a volume. Never in the container layer. A world in a container layer is a world that a redeploy destroys.
- [ ] Join it to the stack network.
- [ ] Downstream config, all three required, carried as flags in `POCKETMINE_ARGS` (flags beat `server.properties` and `pocketmine.yml`, `ServerConfigGroup.php:48` and `:98`):
  - `--xbox-auth=false`
  - `--player.verify-xuid=0` (`0`, not `false`: the flag's string is cast, and `(bool)"false"` is true)
  - `--auto-report.enabled=0`, so crash dumps, which carry config and player data, stay off the public crash archive. Also `0`, never `false`, for the same cast (`images/compose.yaml`, `instance`).
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
- [ ] Confirm the schema is current: the instance must not boot against a database with pending migrations. Run `migrations/run-migrations.sh` first, with `GRANTS_FILE` and every `RIFTAL_DB_PASSWORD_<NAME>`, `RIFTAL_DB_PASSWORD_BACKUP` and the new instance's plugin logins included. Its last phase provisions them (`migrations/README.md`, Provisioning logins). Run it again after every `restore.sh`, since a dump carries no roles or logins.

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
- [ ] The container reports `healthy` once the start period is over, and its restart policy is `on-failure` (`docker inspect --format '{{.HostConfig.RestartPolicy.Name}} {{.State.Health.Status}}'`).

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
