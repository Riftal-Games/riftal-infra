# instance-only plugins

Plugins mounted onto the `instance` service alone, not `instance-b`
(`../../compose.yaml`). `RiftalDevBots.php` one level up is a single script
both instances want; the two files here are not, because `RiftalMines`
resets the worlds `instance` hosts and no others. `instance-b` never mounts
this folder, so a per-instance plugin roster stays a compose-level choice
instead of a shared plugin directory quietly handing every instance the
same plugin.

Both files below are gitignored: `*.phar` by the repo root's `.gitignore`,
`RiftalMines.config.yml` by this folder's own (it carries a real database
password once rendered). Only `RiftalMines.config.yml.template` is tracked.

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

Building from a plain copy of `mines/` and `lib/`, not a bind mount of the
live repo, keeps `composer install`'s `vendor/` out of a working tree another
lane may have open. `wslc` has no bind-mount-then-copy step of its own,
so translate the two `-v` and `-w` flags the same way `/dev-stack` translates
`compose.yaml`'s.

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

A phar that never got built at all mounts as an empty directory (see below)
and is silently ignored rather than failing loudly, so this check, or reading
`Loading RiftalMines` in the boot log, is the only way to catch that before it
becomes a boot that silently never had the plugin at all.

## Render the config override

```sh
set -a; . ../../.env; set +a
./render-config.sh
```

`RiftalMines.config.yml` now carries the real `MYSQL_ROOT_PASSWORD`. Rerun
after editing `.env`.

## Why an override is required, not optional

`mines/resources/config.yml`'s shipped default (`host: riftal-mysql, schema:
riftal, username: mines`) matches nothing on this stack: the MySQL service's
actual resolvable alias is `mysql` under both the compose and wslc forms, the
database compose creates is `riftal_dev`, and no `mines` MySQL user has ever
been provisioned here. Mounting the phar without this override does not fail
the plugin alone — `RiftalGames\Lib\Database\ConnectionProvider::open()` in
`Main::onEnable()` connects synchronously, so a `SqlError` there is uncaught
and takes the whole server down. Verified 2026-09-28: `RiftalMines.phar`
mounted with no config override, on a throwaway MySQL and instance pair,
logs

```
[Server thread/CRITICAL]: ...SqlError: "SQL CONNECT error: php_network_getaddresses:
getaddrinfo for riftal-mysql failed: Name or service not known"
[Server thread/EMERGENCY]: An unrecoverable error has occurred and the server has crashed.
```

within 4 seconds of boot, every time. The render step above is not a nicety.

Both files here are gitignored, so a clone that has built neither yet is the
default state `compose.yaml` has to tolerate. Verified 2026-09-28: a missing
bind-mount source becomes an empty directory at the container path, not a
missing one, and an empty directory named `RiftalMines.phar` is silently
ignored by the plugin loader; a boot with neither file built reaches `Done`
exactly as it did before this folder existed. Build and render before
expecting `RiftalMines` to actually be there.

## `lumber` and the shared MySQL row

`MineWorldLoader` (riftal-game#49) logs and skips a world with no folder on
disk instead of crashing, so mounting `RiftalMines.phar` before the `lumber`
world exists in `riftal-world` is safe: the log carries one error line naming
`lumber`, and the plugin otherwise enables normally. Land the built world
under `riftal-world`'s `worlds/lumber` once `riftal-game`'s DesignBridge
plugin exposes the write ops `build_mine --apply` needs (`create_world`,
`pregen`, `set_blocks`/`fill`; tracked under riftal-game's `lane:bridge`
issues, not yet wired into `Main.php`'s dispatcher as of 2026-09-28) to turn
that log line into a loaded world.
