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
wslc build -t <tag> -f <dockerfile> --build-arg K=V <dir>
wslc logs <name>
wslc exec <name> <cmd>
wslc attach <name>
wslc inspect <name>
wslc network create <net>
wslc network remove <net>
wslc stop <name> && wslc remove <name>
```

`wslc run` takes `-d`, `-i`, `--rm`, `--name`, `--network`, `--network-alias`,
`-p`, `-v`, `-e`, `--memory` and `--cpus`, as the steps below use them. Every
`wslc run` there that starts a line has to match its `images/compose.yaml`
service, and `.github/scripts/wslc-drift.sh .claude/skills/dev-stack/SKILL.md`
checks that by hand, so this list names no template form of it. CI runs the
script against `docs/dev-stack-two-instance.md` only.

All of it was exercised on 2026-09-12, WSL 2.9.4.0, by the bring-up below.
`--network-alias` especially: the decision log's 2026-09-07 entry lists a
narrower flag set and reads as though it might not exist.

Nothing is installed on the Windows host. No PHP, no composer, no MySQL client, no Docker Desktop. If a step here wants one of those, run it in a container instead. Reaching for a host install is the wrong answer every time.

`wslc` is local only. Nothing you write in a Dockerfile or a compose file may depend on it, because production does not have it.

## Verified capabilities

Tested on 2026-08-23, WSL 2.9.4.0. Do not re-derive these:

- `ubuntu:24.04` runs, 16 cores and 30 GB visible.
- Bind mounts of Windows repo paths work read and write.
- UDP publishing works. A full round trip on `19132/udp` from the Windows host into a container and back was confirmed. This was the make-or-break test, since Bedrock is RakNet over UDP.
- `mysql:8` runs as 8.4.11 and is reachable from Windows on the published port.

## Reaching the server from a phone or console

The instance runs `--xbox-auth=false`, so it publishes on `127.0.0.1` only and
nothing here moves it off loopback. `INSTANCE_BIND` stays `127.0.0.1` in
`images/.env`, and `dev-stack.ps1 start` refuses an instance published on any
other address (riftal-pm#534). No instance started with `--xbox-auth=false` is
published by hand on any address but `127.0.0.1` (steward, riftal-pm#491).

Every client on this machine joins through the relay `dev-stack.ps1` starts on
the wslc engine, `devtools/relay.js` on `127.0.0.1:19142`, which forwards to the
instance's loopback publish. The relay binds `127.0.0.1` unless `RELAY_BIND` is
set. Under `-Engine docker` no relay starts, so there is no phone path there
(ADR 019).

**A phone or console join is Nasir's own act at a play test**, never an agent's
step (riftal-pm `CLAUDE.md`, Current state; steward, riftal-pm#491 and #771).
He does all of it himself:

1. Sets `RELAY_BIND` before `dev-stack.ps1 restart`.
2. Adds an inbound UDP 19142 allow rule on the **Private** profile. None
   exists. The only `node.exe` allow rules are on the Public profile, and
   relying on them would hand the xbox-auth-off instance to any device on a
   Public network, so he opts in only on his own Private network.
3. Restarts without `RELAY_BIND` afterwards.

No agent, script, skill, scenario or rig binds the relay off `127.0.0.1`, sets
`RELAY_BIND`, adds that firewall rule or publishes the instance off loopback.
A verdict earned through a relay bound elsewhere is not evidence. Never forward
any of these ports on the router.

## Prerequisites, once

- [ ] `git -C ../pmmp-core submodule update --init --recursive`. `build/php` is a submodule and the core image build copies `build/php/compile.sh` in its first stage. Without it the build fails immediately.
- [ ] Confirm `wslc version` responds. If not, `wsl --version` must be 2.9.3 or newer.
- [ ] Copy `images/.env.example` to `images/.env` and set `MYSQL_ROOT_PASSWORD`. It is gitignored. MySQL refuses to initialise without it.
- [ ] In the same file set `RIFTAL_DB_PASSWORD_BACKUP` and one `RIFTAL_DB_PASSWORD_<NAME>` per plugin login `.env.example` lists: `MINES`, `RANKS`, `ECONOMY`, `ACCOUNTS`. Each is at least 24 characters, `[A-Za-z0-9]` only, or the migration runner refuses it. `INSTANCE_ID` ships set to `dev-1`; a line ending in `=` needs its value.

## Bring it up

`images/compose.yaml` is the definition: the `riftal-dev` network, `mysql`, and
one core `instance`. There is no proxy. WaterdogPE is deferred until instances
actually split, so a client connects to the instance itself
(`../docs/decision-log.md`, 2026-09-12).

Order still matters and is the same order `/deploy-release` uses: database,
then instances. `depends_on` encodes it, gated on MySQL's healthcheck.

**Run these with `wslc`.** There is no `docker` on this machine and there is not
going to be. `wslc` has no `compose` verb, so the commands below are the hand
translation of `compose.yaml` and are the primary form here; the `docker`
equivalents are in the last section. Run them from Git Bash with
`MSYS_NO_PATHCONV=1` so the `C:/...` mount arguments survive. `--network-alias`
is what makes the database answer to `mysql`, as compose's service name does.

`images/.env` is the single place both paths read `MYSQL_ROOT_PASSWORD`,
`INSTANCE_BIND`, `INSTANCE_ID` and the `RIFTAL_DB_PASSWORD_*` values from.
`docker compose` reads it on its own; `wslc` has never heard of it, so the last
line below sources it, and skipping that line starts MySQL with an empty
password and the instance with no identity. Re-run the block in every shell
that runs a command below, and again after editing `.env`.

```sh
export MSYS_NO_PATHCONV=1
INFRA=C:/Users/nasir/riftal-games/riftal-infra
CORE=C:/Users/nasir/riftal-games/pmmp-core
set -a; . "$INFRA/images/.env"; set +a
```

### 1. Build the core image

Only when it is missing or `pmmp-core` changed. The first build compiles the
custom PHP binary and takes 20 to 40 minutes on this machine. Later builds
reuse that layer, which is why the Dockerfile splits PHP into its own stage. Do
not restructure that.

```sh
wslc build -f "$CORE/docker/Dockerfile" -t local-pocketmine-mp \
  --build-arg GIT_HASH="$(git -C "$CORE" rev-parse HEAD)" "$CORE"
```

### 1b. The built levels

`instance` seeds `lumber` and `mine_a` onto `riftal-world` from
`riftal_smoke_level_lumber` and `riftal_smoke_level_mine_a`, which it mounts
read-only at `/etc/riftal/levels/<zone>`, and lists both in
`RIFTAL_LEVEL_ZONES`. Each volume is built, never created by the stack: run
`designer level build <zone>` for the engine in use
(`designer/levels/README.md`, `DESIGNER_RUNTIME`) before the first bring-up. A
volume that is missing or was never fully built stops the boot before
PocketMine starts, with one `seed-levels:` line naming
`riftal_smoke_level_<zone>` and that command. A `wslc run -v` of a missing name
may create it empty, which the seed step then refuses the same way.
`instance-b` lists no zone and mounts no level. A zone already in
`riftal-world` is never replaced, so only a fresh `riftal-world` is seeded
(`images/README.md`, The built levels).

### 2. Network

```sh
wslc network create riftal-dev
```

### 3. MySQL

```sh
wslc run -d --name riftal-mysql --network riftal-dev --network-alias mysql \
  --memory 1G --cpus 1 \
  -p 127.0.0.1:3306:3306 \
  -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" -e MYSQL_DATABASE=riftal_dev \
  -v riftal-mysql:/var/lib/mysql mysql:8

wslc logs riftal-mysql
```

- [ ] The log reaches a `ready for connections` line saying **`port: 3306`**.
      Match the port, never an occurrence count: a first boot on an empty volume
      initialises the datadir behind a temporary server and logs an earlier
      `port: 0` line, and every boot after that logs only the `port: 3306` one.
      MySQL logs to stderr, so piping `wslc logs` to `grep` matches nothing and
      proves nothing.

`wslc run` has no healthcheck flag worth wiring up, so the compose
`depends_on: service_healthy` gate does not apply here. That log line is the
gate instead, and starting the instance before it appears produces failures
that look like schema bugs.

### 4. Migrations and logins

Every plugin connects to MySQL as its own login (ADR 008), and those logins are
created by the migration runner, not by MySQL's entrypoint. An instance started
before this step fails at its first plugin login. The runner applies pending
migrations under a MySQL named lock, applies `grants.sql`, then creates or
rotates each login whose password it is given, so run it again after changing
a password in `images/.env` and after every `restore.sh`
(`migrations/README.md`, Provisioning logins).

`dev-stack.ps1` does this itself under docker only. Under wslc the run is by
hand and spends three bind mounts of wslc's session cap, so check
`dev-stack.ps1 wslc-mounts` first. Each password is passed by name, exported
from `images/.env` by the block at the top, so none reaches the command line;
`MYSQL_PASSWORD` is the root password the runner connects as. `timeout` bounds a
run that waits on the lock (`migrations/README.md`, Running it locally).

```sh
export MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD"
timeout 120 wslc run --rm --memory 1G --cpus 1 --network riftal-dev \
  -v "$INFRA/migrations/run-migrations.sh:/run-migrations.sh:ro" \
  -v "$INFRA/../riftal-game/lib/resources/sql/migrations:/migrations:ro" \
  -v "$INFRA/../riftal-game/lib/resources/sql/grants.sql:/grants.sql:ro" \
  -e MYSQL_HOST=mysql -e MYSQL_USER=root -e MYSQL_PASSWORD -e MYSQL_DATABASE=riftal_dev \
  -e MIGRATIONS_DIR=/migrations -e GRANTS_FILE=/grants.sql \
  -e RIFTAL_DB_PASSWORD_MINES -e RIFTAL_DB_PASSWORD_RANKS \
  -e RIFTAL_DB_PASSWORD_ECONOMY -e RIFTAL_DB_PASSWORD_ACCOUNTS \
  mysql:8 bash /run-migrations.sh
```

- [ ] It exits 0, and its output has `applying grants from /grants.sql` with no
      `failed` line after it. A nonzero exit names the failed migration or the
      login it refused: a password under 24 characters or outside
      `[A-Za-z0-9]`, or a `grants.sql` that is not a file. Do not start the
      instance after one.

### 5. Instance

This is compose's `instance` service by hand, flag for flag. CI does not check
it: after editing this run or compose, run `.github/scripts/wslc-drift.sh` on
this file by hand. `dev-stack.ps1` refuses to start an instance
that differs from it (riftal-pm's `devtools/instance-shape.js`, `check wslc`):
no `--auto-report.enabled=0`, no `INSTANCE_ID`, login password, index or level
mount, a different command, or a UDP publish on anything but `127.0.0.1`. The
instance runs `--xbox-auth=false`, so `INSTANCE_BIND`, read from `images/.env`
and `127.0.0.1` when unset, stays `127.0.0.1`. A device joins through the relay,
never this publish (see Reaching the server from a phone or console, above).
The instance is given no root password. Run step 4 first, with the block above re-sourced,
and build `RiftalCustody.phar` and `RiftalAccounts.phar` first:
`require-custody.sh` and `require-accounts.sh` stop the boot without them
(`images/README.md`).

```sh
wslc run -d -i --name riftal-instance --network riftal-dev \
  --memory 2G --cpus 2 \
  -p "${INSTANCE_BIND:-127.0.0.1}:19132:19132/udp" \
  -v riftal-world:/data -v "$INFRA/images/plugins:/plugins" \
  -v riftal-capture:/capture:ro \
  -v "$INFRA/designer/world_index.json:/etc/riftal/world_index.json:ro" \
  -v riftal_smoke_level_lumber:/etc/riftal/levels/lumber:ro \
  -v riftal_smoke_level_mine_a:/etc/riftal/levels/mine_a:ro \
  -e "INSTANCE_ID=${INSTANCE_ID}" \
  -e "RIFTAL_LEVEL_ZONES=lumber mine_a" \
  -e "RIFTAL_DEV_ENV=1" \
  -e "RIFTAL_DB_PASSWORD_MINES=${RIFTAL_DB_PASSWORD_MINES}" \
  -e "RIFTAL_DB_PASSWORD_RANKS=${RIFTAL_DB_PASSWORD_RANKS}" \
  -e "RIFTAL_DB_PASSWORD_ECONOMY=${RIFTAL_DB_PASSWORD_ECONOMY}" \
  -e "RIFTAL_DB_PASSWORD_ACCOUNTS=${RIFTAL_DB_PASSWORD_ACCOUNTS}" \
  -e "POCKETMINE_ARGS=--level-name=mine_a --level-type=normal --xbox-auth=false --motd=riftal-dev --riftal-dev-bots=on --auto-report.enabled=0" \
  local-pocketmine-mp bash /plugins/restart/boot-gate.sh \
  bash /plugins/deliver-world-index.sh bash /plugins/seed-levels.sh \
  bash /plugins/require-accounts.sh bash /plugins/require-custody.sh \
  bash /plugins/instance-only/start-instance.sh

wslc logs riftal-instance
```

- [ ] The log reaches the line starting `Done (`. Its absence is the failure,
      because a boot that dies still exits 0.
- [ ] No line matches `/(EMERGENCY|ALERT|CRITICAL|ERROR)]`. PocketMine's log
      layout is `%s[%s/%s]: %s` filled with thread then level
      (`MainLogger.php:38` and `:192`), so every severity prints as
      `[<thread>/<LEVEL>]` and the literals `[CRITICAL]` and `[ERROR]` match
      nothing on any boot. A check written that way passes the broken boots
      too. The four levels above `WARNING` are at `MainLogger.php:84-96`.
      Confirmed against a boot broken with a malformed plugin phar, which
      logged `[Server thread/CRITICAL]` and `[Server thread/EMERGENCY]` lines,
      never reached `Done (`, and still exited **0**. How many of each depends
      on how the boot was broken, so count nothing and match the pattern.
- [ ] `Online mode is disabled` appears. That is `--xbox-auth=false` taking
      effect, and its absence means the flag did not arrive.
- [ ] `wslc inspect riftal-instance` lists `POCKETMINE_ARGS` ending
      `--auto-report.enabled=0`. The value has to be `0`: PocketMine casts the
      flag's string, and `(bool) "false"` is true, which uploads crash dumps
      publicly.
- [ ] `start.sh` prints a `WARNING` that files under `/plugins` are not owned by
      `pocketmine` when that directory is a bind mount from Windows. The warning
      is about writes and nothing writes there at runtime.

## Verify

- [ ] A RakNet ping answers on the published port. A pong carries the protocol
      and MOTD, so it proves the UDP path and what is advertised on it, and
      nothing more. Reaching the server is not joining it.
- [ ] A client joins and spawns in the right world.
- [ ] A database write round-trips: trigger it, then read it back from MySQL
      directly. What the plugin printed to chat is not evidence.
- [ ] Replace the instance container, not just restart it, and confirm the
      world and the database survived. A restart reuses the same container
      layer and so proves nothing about where state is written. Held on
      2026-09-12: `Generating spawn terrain` went from 11 lines on the first
      boot to 0 on the replacement, which instead logged `Preparing world
      "mine_a"` off the volume.

**Nothing here has been tested from a physically separate device.** A bridged
WSL distro is a real second host on the LAN but it is not a phone.

## Two instances

Needed for anything cross-instance, and worth doing early because cross-instance bugs are the expensive kind.

- [ ] Run a second core container on the same network, same image tag, different `instance_id` and world list, against the **same** MySQL.
- [ ] Join each with a different account and confirm a change made on one is visible on the other.

This is also the point at which a proxy earns its place, and the point at which
an instance port stops being published to a host interface at all.

That this is cheap is the whole argument for containers. If it ever stops being cheap, the stack has drifted and that is worth saying out loud.

## Tear down

Stop the instance first, and give it time: an abrupt halt can corrupt a world
mid-write. `wslc stop` with a grace period is a clean shutdown. PocketMine runs
as PID 1 (`start.sh` ends in `exec php`) and traps SIGTERM into the same
`shutdown()` the console `stop` runs. Measured 2026-09-27: `Unloading world`,
`Stopping other threads`, exit code 0.

Prefer it to the console. Once anything closes the container's stdin, for
example an `echo list | wslc attach` whose attach is then killed, the console
reader sees EOF and never reads again, and `echo stop | wslc attach` then does
nothing at all.

```sh
wslc stop -t 60 riftal-instance
wslc logs riftal-instance
wslc inspect riftal-instance
wslc remove riftal-instance

wslc stop riftal-mysql
wslc remove riftal-mysql
wslc network remove riftal-dev
```

`wslc attach` still forwards piped stdin to a container started with `-d -i`,
for console commands other than stopping. `wslc list` hides exited containers,
so read `"Status"` and `"ExitCode"` from `inspect` before removing one.

- [ ] The shutdown sequence reached the log: `Unloading world`, then
      `Stopping other threads`, and `inspect` shows exit code 0. Only then is
      the container safe to remove.
- [ ] `INSTANCE_BIND` reads `127.0.0.1` in `images/.env`, and the relay runs
      without `RELAY_BIND`. After a play test, restarting without `RELAY_BIND`
      is Nasir's own step, as is the firewall rule he added for it; no agent
      changes either.
- [ ] **Leave the named volumes.** `riftal-mysql` and `riftal-world` hold the
      dev database and world. Removing either is a reset, never the routine
      ending.
- [ ] Nothing left running. Orphaned containers holding published ports are the
      usual reason the next bring-up fails with a port conflict.

## When it will not come up

In this order, because each rules out the ones below it:

1. `wslc list` and `wslc logs <name>`. Read the actual error before theorizing.
2. Port conflict. An earlier container still holds `19132`. Remove it.
3. MySQL exits immediately with `[ERROR] [Entrypoint]: Database is uninitialized and password option is not specified`. The shell never sourced `images/.env`, so `MYSQL_ROOT_PASSWORD` was empty. Re-run the export block and start the container again; nothing was written, so there is nothing to clean up.
4. Instance cannot reach MySQL. Both on the same network? Using the container name, not `localhost`? `localhost` inside a container is that container.
5. Client cannot join but the container looks healthy. Check that the publish is `/udp`. This is the most common single mistake in this stack.
6. A phone or console cannot see the server while a client on this machine can. That is the expected state: the instance and the relay are on `127.0.0.1`, and only Nasir opens a phone path, at a play test. See Reaching the server from a phone or console, above.
7. Login fails with something that looks like a protocol error. Check `xbox-auth=false`. Behind a proxy `player.verify-xuid: false` is required too, and missing either produces exactly that symptom and it is not a protocol bug. Direct, there is no proxy stripping the XUID, so the default stays.
8. Build fails in the first stage. `build/php` submodule is empty. See prerequisites.
9. The instance exits at once, or `dev-stack.ps1` refuses to start it. The
   refusal names what is missing: `--auto-report.enabled=0`, the command,
   `INSTANCE_ID`, a login password, the index or a level mount. A `seed-levels:`
   line means a level volume is missing or unbuilt, see step 1b. A boot that
   reaches a plugin login and fails there means step 4 was skipped or
   `images/.env` changed since: run it again.

## The docker form

**Not runnable on this machine.** `which docker` returns nothing here. This is
here to read, not to follow: it is what `images/compose.yaml` means on a
standard runtime. CI checks that file with `compose config --quiet`
(`.github/scripts/scan.sh:15`) and never starts it, so nothing has run `up` on
these services anywhere.

```sh
cd images
docker compose up -d --wait
docker compose logs -f instance
docker compose down
```

`--wait` holds until the MySQL healthcheck passes, which is the piece `wslc` has
no equivalent for and the reason the local bring-up waits on a log line instead.

`up` runs `dump-login`, which provisions the `backup` login alone
(`images/compose.yaml`, `dump-login`). The plugin logins still need step 4's
runner, as a `docker run` with the same mounts and variables, between MySQL
turning healthy and `instance` starting: `docker compose up -d --wait mysql`,
the runner, then the full `up`. `dev-stack.ps1 -Engine docker` does that run
itself.

## Rules

Never point the local stack at the production database. Never run a local instance with its port published on a public interface, since it is in offline mode. If a local test needs production data, ask Nasir first, and snapshot before touching anything.
