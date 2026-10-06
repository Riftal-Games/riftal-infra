# instance-only plugins

Plugins the `instance` service loads and `instance-b` does not
(`../../compose.yaml`). `RiftalDevBots.php` one level up is a single script
both instances want; `RiftalMines` is not, because it resets the worlds
`instance` hosts and no others.

Both instances see this folder through the shared `./plugins` bind, and
PocketMine never loads from a subfolder, so `instance-b` ignores it.
`instance` runs `start-instance.sh` instead of the image's `start-pocketmine`:
it assembles its plugin roster in the container's own disposable filesystem
and renders the config onto the volume as uid 1000. It otherwise
does what `start-pocketmine` does for `instance-b`: the ownership warning,
`POCKETMINE_PLUGINS` from Poggit (into the roster, never `./plugins`) and
`POCKETMINE_ANSI`. `start-pocketmine` hard-codes `--plugins=/plugins`, so
it cannot be reused. `selftest.sh` pins this script's copy of that
behaviour but never reads core's `docker/start.sh`, so a change there has to
be carried into `start-instance.sh` by hand. Nothing is
bind-mounted inside `/plugins` or `/data`, because Docker creates a missing
mountpoint as root: a stray in `./plugins` that `instance-b` then fails to
load, or a `/data/plugin_data` PocketMine cannot write in. `selftest.sh`
fails on either.

`*.phar` is gitignored by the repo root's `.gitignore`, and
`RiftalMines.config.yml` by this folder's own, since a copy rendered by hand
carries a real database password. Only `RiftalMines.config.yml.template` is
tracked.

## Build `RiftalMines.phar`

`mines` has real Composer dependencies (`sof3/libasynql`, the `lib` path-repo
virion), so it needs `pharynx`, the same tool and pin
`riftal-game/.github/workflows/ci.yml` uses, run against a PHP that carries
every PocketMine extension. `local-pocketmine-mp`'s runtime PHP has them
already; it has no Composer, so bring one as a phar too.

```sh
curl -fsSLo /tmp/pharynx.phar \
  https://github.com/SOF3/pharynx/releases/download/0.3.8/pharynx.phar
echo "de84964df51d595a9d521ee42df010cf6e817b1e5ceef17de6ef884c41b28133  /tmp/pharynx.phar" | sha256sum -c -
curl -fsSLo /tmp/composer-setup.php https://getcomposer.org/installer
php /tmp/composer-setup.php --install-dir=/tmp --filename=composer.phar

GAME=../../../../riftal-game
BUILD=$(mktemp -d)
mkdir -p "$BUILD/mines" "$BUILD/lib"
cp -r "$GAME/mines/." "$BUILD/mines/"
cp -r "$GAME/lib/." "$BUILD/lib/"

docker run --rm \
  -v "$BUILD:/build" -v "$PWD:/out" \
  -v /tmp/pharynx.phar:/pharynx.phar:ro -v /tmp/composer.phar:/composer.phar:ro \
  -w /build/mines -e COMPOSER_ALLOW_SUPERUSER=1 -e HOME=/tmp \
  local-pocketmine-mp sh -c '
    php /composer.phar install --prefer-dist --no-interaction --no-progress --no-dev
    php -dphar.readonly=0 /pharynx.phar -i . -c "-p=/out/RiftalMines.phar"
  '
```

Building from a copy of `mines/` and `lib/`, not a bind mount, keeps
`composer install`'s `vendor/` out of a working tree another lane may have
open. Under `wslc`, translate the `-v` and `-w` flags as `/dev-stack` does.

Confirm the build holds a `plugin.yml`, the same check
`riftal-game/.github/scripts/packages.sh`'s `phar_one()` runs on every phar it
builds:

```sh
docker run --rm -v "$PWD/RiftalMines.phar:/p.phar:ro" local-pocketmine-mp php -r '
  foreach (new RecursiveIteratorIterator(new Phar("/p.phar")) as $f) {
    if (basename((string) $f) === "plugin.yml") { exit(0); }
  }
  fwrite(STDERR, "no plugin.yml found inside the built phar\n");
  exit(1);
'
```

A phar that was never built is skipped without a word (see below), so this
check, or reading `Loading RiftalMines` in the boot log, is the only way to
catch a boot that silently never had the plugin at all.

## The config override

With `RiftalMines.phar` present, `start-instance.sh` runs `render-config.sh`
on every boot, writing the template to
`/data/plugin_data/RiftalMines/config.yml` with the container's own
`MYSQL_ROOT_PASSWORD`. Compose passes `instance` the same `images/.env` value
it passes `mysql`, so the two cannot disagree; a `wslc run` of `instance`
needs `-e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"` for the same reason.
Unset, the boot stops before PocketMine starts and names the variable. No
file rendered into this folder is read.

## Why an override is required, not optional

`mines/resources/config.yml`'s shipped default (`host: riftal-mysql, schema:
riftal, username: mines`) matches nothing on this stack under compose: the
`mysql` service sets no `container_name`, so on `riftal-dev` it answers to
`mysql` and not to `riftal-mysql` (checked 2026-10-06 with `getent hosts` on
a throwaway compose network of the same shape), the database compose creates
is `riftal_dev`, and no `mines` MySQL user has ever been provisioned here.
Under the `wslc run` form, whose database container is named `riftal-mysql`
on `riftal-dev`, whether either name resolves has not been checked
(riftal-infra#265). The template names `mysql` for compose. Loading the phar without this override does not fail
the plugin alone: `RiftalGames\Lib\Database\ConnectionProvider::open()` in
`Main::onEnable()` connects synchronously, so a `SqlError` there is uncaught
and takes the whole server down within 4 seconds of boot (verified
2026-09-28: `SQL CONNECT error: ... getaddrinfo for riftal-mysql failed`).
A config rendered with a password `mysql` does not have fails the same way,
with `Access denied for user 'root'`, which is why it is rendered at boot
rather than kept here (riftal-infra#266).

The phar is gitignored, so a clone that has not built it is the
default state `compose.yaml` has to tolerate. Verified 2026-09-28, each on a
fresh volume and each stopped with `stop` on stdin: without the phar,
`instance` reaches `Done` with `RiftalDevBots` alone; with it, it loads
`RiftalMines` and reaches `Done` with the one `lumber` line below as its only
error; `instance-b` booted afterwards reaches `Done` without `RiftalMines`;
`/data/plugin_data` is owned by uid 1000 every time, and nothing new appears
in `./plugins`.

## `lumber` and the shared MySQL row

`MineWorldLoader` (riftal-game#49) logs and skips a world with no folder on
disk instead of crashing, so loading `RiftalMines.phar` before the `lumber`
world exists in `riftal-world` is safe: the log carries one error line naming
`lumber`, and the plugin otherwise enables normally. Land the built world
under `riftal-world`'s `worlds/lumber` once `riftal-game`'s DesignBridge
plugin exposes the write ops `build_mine --apply` needs (`create_world`,
`pregen`, `set_blocks`/`fill`; tracked under riftal-game's `lane:bridge`
issues, riftal-infra#239 and riftal-game#8) to turn
that log line into a loaded world.
