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
`RiftalMines.config.yml` by this folder's own, so a copy edited by hand to
hold a database password is never committed. Only
`RiftalMines.config.yml.template` is tracked.

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
`/data/plugin_data/RiftalMines/config.yml`. No file rendered into this folder
is read, and any config an earlier boot left on the volume is replaced.

It connects as the `mines` login of ADR 008, never as root, and the file
carries no password: `DatabaseSettings` reads it from
`RIFTAL_DB_PASSWORD_MINES`, which compose passes `instance` from
`images/.env`, and throws if the file holds one too. So no credential is on
the `riftal-world` volume or in a backup set's tar of it. A `wslc run` of
`instance` needs a name-only `-e RIFTAL_DB_PASSWORD_MINES`, exported first,
for the same reason. Unset, the boot stops before PocketMine starts and names
the variable. `instance` is never given `MYSQL_ROOT_PASSWORD`.

The login itself is made by the migration runner, not by the instance. Run it
before `instance`, with `grants.sql` mounted and `-e RIFTAL_DB_PASSWORD_MINES`
exported from the same `images/.env`, as `../../../migrations/README.md`
shows under "Running it locally". The runner creates `mines`, grants it
`riftal_role_mines`, and resets its password to that value on every run, so
after editing it in `images/.env` run the runner again before the next boot.
A boot before the runner has made the login fails with
`Access denied for user 'mines'`, and a grant `mines` lacks surfaces as
ERROR 1142, which is the point.

## Why an override is required, not optional

`mines/resources/config.yml`'s shipped default (`host: mysql, schema:
riftal, username: mines`) names a schema this stack does not have: the
database compose creates is `riftal_dev`. The `mysql` service sets no
`container_name`, so on `riftal-dev` it answers to `mysql` and not to
`riftal-mysql` (checked 2026-10-06 with `getent hosts` on a throwaway compose
network of the same shape). Under the `wslc run` form, the database container is named `riftal-mysql`
on `riftal-dev` and is started with `--network-alias mysql`, which is meant
to make it answer to `mysql` as the compose service does. Whether either
name resolves there has not been checked (riftal-infra#265). The template
names `mysql` for compose.

Loading the phar without this override does not fail the plugin alone:
`RiftalGames\Lib\Database\ConnectionProvider::open()` in `Main::onEnable()`
connects synchronously, so a `SqlError` there is uncaught and takes the
whole server down within 4 seconds of boot (verified
2026-09-28: `SQL CONNECT error: ... getaddrinfo for riftal-mysql failed`).
A `mines` login the runner has not provisioned, or a
`RIFTAL_DB_PASSWORD_MINES` it was not run with, fails the same way, with
`Access denied for user 'mines'`.

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
