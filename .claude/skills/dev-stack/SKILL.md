---
name: dev-stack
description: Stand up, inspect, or tear down the local container stack: MySQL and one core instance. Use when a local server is needed for development or testing, when joining it from a phone or console, or when the local stack is misbehaving.
when_to_use: Starting local development, needing a database or a running server to test against, or the local stack will not come up.
---

# Local dev stack

The authoritative runbook for the local environment. `riftal-game`'s `/test-server` builds on this rather than repeating it.

Same images and same shape as production, at one instance instead of many. That is the point. A local stack that differs structurally from production is a stack that hides production bugs.

## The runtime

Nasir's machine is Windows 11 and the container CLI is `wslc`, at `C:\Program Files\WSL\wslc.exe`. It ships with WSL, needs 2.9.3 or newer, and takes standard OCI verbs.

```
wslc images
wslc list
wslc build -t <tag> <dir>
wslc run -d --name <name> ...
wslc logs <name>
wslc exec <name> <cmd>
wslc stop <name> && wslc remove <name>
```

Nothing is installed on the Windows host. No PHP, no composer, no MySQL client, no Docker Desktop. If a step here wants one of those, run it in a container instead. Reaching for a host install is the wrong answer every time.

`wslc` is local only. Nothing you write in a Dockerfile or a compose file may depend on it, because production does not have it.

## Verified capabilities

Tested on 2026-08-23, WSL 2.9.4.0. Do not re-derive these:

- `ubuntu:24.04` runs, 16 cores and 30 GB visible.
- Bind mounts of Windows repo paths work read and write.
- UDP publishing works. A full round trip on `19132/udp` from the Windows host into a container and back was confirmed. This was the make-or-break test, since Bedrock is RakNet over UDP.
- `mysql:8` runs as 8.4.11 and is reachable from Windows on the published port.
- `wslc build` builds a Dockerfile and the resulting image runs.

## Reaching the server from a phone or console

Measured on 2026-09-12, WSL 2.9.4.0, `networkingMode=bridged`. Two separate
things have to be right, and getting only the first is the failure that looks
like the server is broken.

**One: the publish has to name `0.0.0.0`.** A bare `-p 19132:19132/udp` binds
the Windows side to `127.0.0.1`, confirmed in `netstat -ano -p UDP`. A probe to
the machine's own LAN address then comes back with an ICMP port unreachable.
`-p 0.0.0.0:19132:19132/udp` binds `0.0.0.0:19132` and that probe pongs.
`INSTANCE_BIND=0.0.0.0` in `images/.env` is the compose form.

**Two: Windows Firewall has to allow inbound UDP 19132.** With the bind
correct, a packet from another host on the LAN is still dropped in silence,
while `ping` to the same address answers with no loss. Silence rather than an
ICMP unreachable is the firewall signature. One rule, once, in an
**Administrator** PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Riftal dev Bedrock 19132 UDP" `
  -Direction Inbound -Action Allow -Protocol UDP -LocalPort 19132 `
  -Profile Private
```

`-Profile Private` on purpose. The LAN adapter is on the Private profile, and a
rule that also covered Public would follow this machine onto untrusted
networks. Remove the rule by display name when the LAN publish is not wanted.

The address a device connects to is the **Windows** LAN address, `ipconfig` on
the `vEthernet (VM Lan Switch)` adapter. The WSL VM's own bridged address does
not serve the published port; probing it gets nothing.

There is no public exposure here and there must not be. The instance runs
offline mode, so the LAN bind is for devices on this house's network only.
Never forward this port on the router.

## Prerequisites, once

- [ ] `git -C ../pmmp-core submodule update --init --recursive`. `build/php` is a submodule and the core image build copies `build/php/compile.sh` in its first stage. Without it the build fails immediately.
- [ ] Confirm `wslc version` responds. If not, `wsl --version` must be 2.9.3 or newer.
- [ ] Copy `images/.env.example` to `images/.env` and set `MYSQL_ROOT_PASSWORD`. It is gitignored. MySQL refuses to initialise without it.

## Bring it up

`images/compose.yaml` is the definition: the `riftal-dev` network, `mysql`, and
one core `instance`. There is no proxy. WaterdogPE is deferred until instances
actually split, so a client connects to the instance itself
(`../docs/decision-log.md`, 2026-09-12).

Order still matters and is the same order `/deploy-release` uses: database,
then instances. `depends_on` encodes it, gated on MySQL's healthcheck.

### 1. Build the core image

Only when it is missing or `pmmp-core` changed. The first build compiles the
custom PHP binary and takes 20 to 40 minutes on this machine. Later builds
reuse that layer, which is why the Dockerfile splits PHP into its own stage. Do
not restructure that.

```sh
docker build -f ../pmmp-core/docker/Dockerfile -t local-pocketmine-mp \
  --build-arg GIT_HASH="$(git -C ../pmmp-core rev-parse HEAD)" ../pmmp-core
```

### 2. Start the stack

From `images/`. `--wait` holds until MySQL's healthcheck passes, so nothing
boots against a database still initialising.

```sh
docker compose up -d --wait
docker compose logs -f instance
```

- [ ] MySQL log reaches `ready for connections` on `port: 3306`. It prints that
      line twice; the first is the init pass on `port: 0` and is not the one to
      wait for.
- [ ] Instance log reaches the line starting `Done (`.
- [ ] Instance log has no `[CRITICAL]`, no `[ERROR]` and no exception.
      PocketMine exits 0 with errors in the log, so the log is the verdict and
      the exit code is not.
- [ ] `Online mode is disabled` appears. That is `--xbox-auth=false` taking
      effect, and its absence means the flag did not arrive.

## Verify

- [ ] A RakNet ping answers on the published port. A pong carries the protocol
      and MOTD, so it proves the UDP path and what is advertised on it, and
      nothing more. Reaching the server is not joining it.
- [ ] A client joins and spawns in the right world.
- [ ] A database write round-trips: trigger it, then read it back from MySQL
      directly. What the plugin printed to chat is not evidence.
- [ ] Replace the instance container, not just restart it, and confirm the
      world and the database survived. A restart reuses the same container
      layer and so proves nothing about where state is written.

## Local convenience: wslc

`wslc` has no `compose` verb, so `images/compose.yaml` is translated to `run`
flags by hand. Nothing in the compose file depends on `wslc`; production runs
standard docker. Run from Git Bash with `MSYS_NO_PATHCONV=1` so path arguments
survive. `--network-alias` is what makes the container answer to `mysql`, the
same name compose gives the service.

```sh
export MSYS_NO_PATHCONV=1
wslc network create riftal-dev

wslc run -d --name riftal-mysql --network riftal-dev --network-alias mysql \
  -p 127.0.0.1:3306:3306 \
  -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" -e MYSQL_DATABASE=riftal_dev \
  -v riftal-mysql:/var/lib/mysql mysql:8

wslc logs riftal-mysql

wslc run -d -i --name riftal-instance --network riftal-dev \
  -p "${INSTANCE_BIND:-127.0.0.1}:19132:19132/udp" \
  -v riftal-world:/data \
  -e "POCKETMINE_ARGS=--level-name=mine_a --level-type=normal --xbox-auth=false --motd=riftal-dev" \
  local-pocketmine-mp

wslc logs riftal-instance
echo stop | wslc attach riftal-instance
wslc inspect riftal-instance
wslc remove riftal-instance
```

`wslc attach` forwards piped stdin to a container started with `-d -i`, so that
is the console path. `wslc list` hides exited containers, so read `"Status"` and
`"ExitCode"` from `inspect` before removing one.

`wslc run` has no `--health-*` equivalent worth wiring up here, so the compose
healthcheck does not apply and `ready for connections` in the log is what to
wait on instead.

## Two instances

Needed for anything cross-instance, and worth doing early because cross-instance bugs are the expensive kind.

- [ ] Run a second core container on the same network, same image tag, different `instance_id` and world list, against the **same** MySQL.
- [ ] Join each with a different account and confirm a change made on one is visible on the other.

This is also the point at which a proxy earns its place, and the point at which
an instance port stops being published to a host interface at all.

That this is cheap is the whole argument for containers. If it ever stops being cheap, the stack has drifted and that is worth saying out loud.

## Tear down

Stop the instance through its console first. `stop` on stdin is the only clean
shutdown; an abrupt halt can corrupt a world mid-write.

```sh
echo stop | docker attach "$(docker compose ps -q instance)"
docker compose logs instance | tail -n 5
docker compose down
```

- [ ] The shutdown sequence reached the log: `[CONSOLE: Stopping the server]`,
      `Unloading world`, then `Stopping other threads`. Only then is the
      container safe to remove.
- [ ] **Leave the named volumes.** `down` keeps them; `down -v` destroys the dev
      world and database and is never the routine ending.
- [ ] Nothing left running. Orphaned containers holding published ports are the
      usual reason the next bring-up fails with a port conflict.

## When it will not come up

In this order, because each rules out the ones below it:

1. `wslc list` and `wslc logs <name>`. Read the actual error before theorizing.
2. Port conflict. An earlier container still holds `19132`. Remove it.
3. Instance cannot reach MySQL. Both on the same network? Using the container name, not `localhost`? `localhost` inside a container is that container.
4. Client cannot join but the container looks healthy. Check that the publish is `/udp`. This is the most common single mistake in this stack.
5. A phone or console cannot see the server while a client on this machine can. The bind, then the firewall, in that order. See the section above.
6. Login fails with something that looks like a protocol error. Check `xbox-auth=false`. Behind a proxy `player.verify-xuid: false` is required too, and missing either produces exactly that symptom and it is not a protocol bug. Direct, there is no proxy stripping the XUID, so the default stays.
7. Build fails in the first stage. `build/php` submodule is empty. See prerequisites.

## Rules

Never point the local stack at the production database. Never run a local instance with its port published on a public interface, since it is in offline mode. If a local test needs production data, ask Nasir first, and snapshot before touching anything.
