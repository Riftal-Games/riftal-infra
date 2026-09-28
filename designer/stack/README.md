# Designer stack

One core container, no proxy, no database. It also admits dev bots on
request; see [Bot scenarios](#bot-scenarios). `compose.yaml` is the definition;
the commands below are its standard docker form, followed by the `wslc` form
for local use. All paths assume this directory as the working directory and
`pmmp-core` as a sibling of `riftal-infra`.

The world lives on the named volume `designer-world`. Containers are
disposable, that volume is not. Never `down -v`, never `volume remove` it.

## Port

The instance's RakNet port publishes to host `19134/udp` by default, not
`19132`. The regular dev stack (`../../images/compose.yaml`, run by
`/dev-stack`) already holds `19132` for its always-on instance and `19133` for
its second one, so `19132` here would collide with it and one of the two
stacks would fail to bind, or silently steal the port depending on the
container engine. `19134` lets both stacks run at once, each answering its
own pong on its own port. Override with `DESIGNER_GAME_PORT` if `19134` is
also taken:

```sh
DESIGNER_GAME_PORT=19135 docker compose up -d
```

## Token

`DESIGNBRIDGE_TOKEN` has no default in `compose.yaml`. DesignBridge disables
itself on an empty token, so an unset one fails safe instead of falling back
to a literal every clone of this repo would otherwise carry. Export a value
before starting the stack, matching `designer/.env.example`'s empty
`DESIGNER_TOKEN`, which the toolkit reads to talk to the same plugin:

```sh
export DESIGNBRIDGE_TOKEN=choose-your-own-value
```

## Build the core image

The first build compiles PHP and takes 20 to 40 minutes. Later builds reuse
that layer.

```sh
docker build -f ../../../pmmp-core/docker/Dockerfile -t local-pocketmine-mp \
  --build-arg GIT_HASH="$(git -C ../../../pmmp-core rev-parse HEAD)" \
  ../../../pmmp-core
```

## Build DevTools.phar

Core ships only the phar and script plugin loaders. DevTools carries the folder
loader that lets a source tree such as `DesignBridge` load directly, so it must
be present as a phar first. It is built with its own `ConsoleScript.php`, run by
the PHP inside the core image, and lands in `plugins/`, which is gitignored.

```sh
docker run --rm \
  -v "$PWD/../../../pmmp-core/tests/plugins/DevTools:/src:ro" \
  -v "$PWD/plugins:/out" \
  local-pocketmine-mp \
  php -dphar.readonly=0 /src/src/ConsoleScript.php \
    --make src,plugin.yml,resources,stub.php --relative /src \
    --stub stub.php --out /out/DevTools.phar
```

## Build a plugin phar

Same tool, any plugin with a `plugin.yml`. Never mount a plugin's phar and its
source folder at once, the server will refuse the duplicate.

```sh
docker run --rm \
  -v "$PWD/../../../riftal-game/designbridge:/src:ro" \
  -v "$PWD/plugins:/out" \
  local-pocketmine-mp \
  php -dphar.readonly=0 /plugins/DevTools.phar \
    --make src,plugin.yml,resources --relative /src --out /out/DesignBridge.phar
```

`compose.yaml` mounts the DesignBridge source by default, so to run from
`DesignBridge.phar` instead, point `DESIGNBRIDGE_SRC` at an empty directory:

```sh
mkdir -p empty
DESIGNBRIDGE_SRC=./empty docker compose up -d
```

## Start

```sh
docker compose up -d
docker compose logs -f designer
```

Ready is the line starting `Done (`; the timing in the parentheses varies per
boot. DevTools is loaded when `[DevTools] Registered folder plugin loader` and
`Enabling DevTools` appear before it. PocketMine logs severity as
`[<thread>/<LEVEL>]`, so check for `/(ERROR|CRITICAL|EMERGENCY|ALERT)]` or an
exception in the log; either one is a failed boot even though the container is
still running.

`start.sh` prints a `WARNING` that files under `/plugins` are not owned by
`pocketmine` when `plugins/` is a bind mount from Windows. The phar still loads;
the warning is about writes, and nothing writes there at runtime.

## Console

The server reads commands on stdin, which `stdin_open: true` keeps open.

```sh
echo 'say hello' | docker attach "$(docker compose ps -q designer)"
```

## Stop cleanly

`stop` on stdin, then wait for the shutdown sequence in the log:
`[CONSOLE: Stopping the server]`, `Disabling DevTools`, `Unloading world
"design"`, `Stopping other threads`. Only then remove the container. An abrupt
stop can corrupt a world mid-write, so never `kill`, and never `down` before
`Stopping other threads`.

```sh
echo stop | docker attach "$(docker compose ps -q designer)"
docker compose logs designer | tail -n 5
docker compose down
```

`down` keeps the named volume.

## Bot scenarios

This stack is the one where a playtester scenario can drive a DesignBridge op
(`fill`, `get_light`) and check both its effect in the world and its audit
line. `images/plugins/RiftalDevBots.php` is mounted here as well, so bots are
admitted under the same three signals as on the dev stack: the
`riftal-dev-bots` flag, `xbox-auth=false`, and `RIFTAL_DEV_ENV=1`. The flag is
`DESIGNER_DEV_BOTS`, `off` by default, so a builder's session never admits
bots it did not ask for.

A scenario edits the world, so it never runs on `designer-world`. Point
`DESIGNER_VOLUME` at a `riftal_smoke_` volume, which the guard lets you remove
afterwards; a name with `world` in it is refused even with that prefix.

```sh
export DESIGNBRIDGE_TOKEN=choose-your-own-value
export DESIGNER_DEV_BOTS=on DESIGNER_VOLUME=riftal_smoke_designbridge
docker compose up -d
```

Before running anything, read the boot log for all of these, plus `Done (`
and no `/(ERROR|CRITICAL|EMERGENCY|ALERT)]`:

- `[RiftalDevBots] dev bots admitted`. `dev bots refused` means
  `DESIGNER_DEV_BOTS` did not reach the container.
- `[DesignBridge] enabled, bridge target 0.0.0.0:19140`. `no token
  configured` means `DESIGNBRIDGE_TOKEN` was empty.

How a scenario reaches the stack, from `riftal-pm/devtools`:

- **Bots** join through a second `relay.js` (see the root `CLAUDE.md` on why
  bots never join a published port directly). `19142` stays the dev stack's
  relay, so this one listens on `19143` and forwards to this stack's game
  port:

  ```sh
  RELAY_PORT=19143 RELAY_UPSTREAM_PORT=19134 node relay.js
  BOT_PORT=19143 node run-scenario.js <name> --container <container>
  ```

  `<container>` is `designer` under `wslc`, or `docker compose ps -q
  designer` under compose; add `--engine docker` for the WSL docker engine.
- **Ops** go to `127.0.0.1:19140` over TCP with `DESIGNBRIDGE_TOKEN`, the same
  protocol `designer/`'s toolkit bridge client speaks.
- **The audit line** is appended to
  `/data/plugin_data/DesignBridge/designbridge.log` inside the container:

  ```sh
  docker compose exec designer cat /data/plugin_data/DesignBridge/designbridge.log
  ```

Under the WSL docker engine (`wsl -d Ubuntu-26.04 -u runner -- docker ...`),
the distro's `127.0.0.1` is its own loopback, not Windows'.

- **`19140` stays on the distro's loopback.** It has no bind override, because
  it edits the world for anyone holding the token. Run the op client inside
  the distro against `127.0.0.1:19140`: a shell from
  `wsl -d Ubuntu-26.04 -u runner`, or a container started with
  `--network host`.
- **The game port has no private route to Windows. This is a known
  limitation.** The distro is bridged onto the LAN, so every address in it
  that Windows can reach is a LAN address. `hostname -I` prints the LAN
  address first. Setting `DESIGNER_GAME_BIND` to that address lets the relay
  reach the stack (`RELAY_UPSTREAM_HOST`, the address `dev-stack.ps1` gives
  its own relay), and it also exposes the offline-mode game port to every
  machine on the LAN. Where that is not acceptable, run bot scenarios under
  `wslc`.

Stop cleanly as above, then `docker volume rm riftal_smoke_designbridge`.

## Export a world folder

A throwaway container reads the volume and copies one world out.

```sh
mkdir -p export
docker run --rm -v designer-world:/data:ro -v "$PWD/export:/out" \
  ubuntu:24.04 cp -r /data/worlds/design /out/
```

## Local convenience: wslc

`wslc` has no `compose`, so the service block is translated to `run` flags by
hand. Nothing in `compose.yaml` depends on this; production runs standard
docker. Run from Git Bash with `MSYS_NO_PATHCONV=1` so the `C:/...:/...` mount
arguments survive.

```sh
export MSYS_NO_PATHCONV=1
INFRA=C:/Users/nasir/riftal-games/riftal-infra
STACK=$INFRA/designer/stack
CORE=C:/Users/nasir/riftal-games/pmmp-core
GAME=C:/Users/nasir/riftal-games/riftal-game
export DESIGNBRIDGE_TOKEN=choose-your-own-value

wslc build -f "$CORE/docker/Dockerfile" -t local-pocketmine-mp \
  --build-arg GIT_HASH="$(git -C "$CORE" rev-parse HEAD)" "$CORE"

wslc run --rm -v "$CORE/tests/plugins/DevTools:/src:ro" -v "$STACK/plugins:/out" \
  local-pocketmine-mp php -dphar.readonly=0 /src/src/ConsoleScript.php \
  --make src,plugin.yml,resources,stub.php --relative /src \
  --stub stub.php --out /out/DevTools.phar

wslc run -d -i --name designer \
  -p "127.0.0.1:${DESIGNER_GAME_PORT:-19134}:19132/udp" -p 127.0.0.1:19140:19140/tcp \
  -v "${DESIGNER_VOLUME:-designer-world}:/data" -v "$STACK/plugins:/plugins" \
  -v "$GAME/designbridge:/plugins/DesignBridge:ro" \
  -v "$INFRA/images/plugins/RiftalDevBots.php:/plugins/RiftalDevBots.php:ro" \
  -e "DESIGNBRIDGE_TOKEN=$DESIGNBRIDGE_TOKEN" -e RIFTAL_DEV_ENV=1 \
  -e "POCKETMINE_ARGS=--level-name=design --level-type=normal --level-seed=20260907 --xbox-auth=false --gamemode=1 --max-players=4 --view-distance=16 --motd=riftal-designer --riftal-dev-bots=${DESIGNER_DEV_BOTS:-off}" \
  local-pocketmine-mp

wslc logs designer
echo stop | wslc attach designer
wslc inspect designer
wslc remove designer
```

`wslc attach` forwards piped stdin to a container started with `-d -i`, so
that is the console path. `wslc list` hides exited containers, so read
`"Status": "exited"` and `"ExitCode": 0` from `inspect` before `remove`.
Published ports bind to `127.0.0.1` by default.
