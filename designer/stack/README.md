# Designer stack

One core container, no proxy, no database. `compose.yaml` is the definition;
the commands below are its standard docker form, followed by the `wslc` form
for local use. All paths assume this directory as the working directory and
`pmmp-core` as a sibling of `riftal-infra`.

The world lives on the named volume `designer-world`. Containers are
disposable, that volume is not. Never `down -v`, never `volume remove` it.

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

The translation omits the DesignBridge source mount. `riftal-game/designbridge`
does not exist yet, and `wslc run` creates a missing bind source, so the flag
would leave a stray empty directory inside the `riftal-game` checkout and mount
nothing. Add `-v "$GAME/designbridge:/plugins/DesignBridge:ro"` once the plugin
exists, and drop it again whenever `DesignBridge.phar` is in `plugins/`.

```sh
export MSYS_NO_PATHCONV=1
STACK=C:/Users/nasir/riftal-games/riftal-infra/designer/stack
CORE=C:/Users/nasir/riftal-games/pmmp-core
GAME=C:/Users/nasir/riftal-games/riftal-game

wslc build -f "$CORE/docker/Dockerfile" -t local-pocketmine-mp \
  --build-arg GIT_HASH="$(git -C "$CORE" rev-parse HEAD)" "$CORE"

wslc run --rm -v "$CORE/tests/plugins/DevTools:/src:ro" -v "$STACK/plugins:/out" \
  local-pocketmine-mp php -dphar.readonly=0 /src/src/ConsoleScript.php \
  --make src,plugin.yml,resources,stub.php --relative /src \
  --stub stub.php --out /out/DevTools.phar

wslc run -d -i --name designer \
  -p 127.0.0.1:19132:19132/udp -p 127.0.0.1:19140:19140/tcp \
  -v designer-world:/data -v "$STACK/plugins:/plugins" \
  -e DESIGNBRIDGE_TOKEN=local-dev-only \
  -e "POCKETMINE_ARGS=--level-name=design --level-type=normal --level-seed=20260907 --xbox-auth=false --gamemode=1 --max-players=4 --view-distance=16 --motd=riftal-designer" \
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
