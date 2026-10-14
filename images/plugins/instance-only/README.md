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
be carried into `start-instance.sh` by hand. `boot-selftest.sh` boots
the pinned core image with the script as it ships, with the phar unbuilt,
built with no password, and built with one. Nothing is
bind-mounted inside `/plugins` or `/data`, because Docker creates a missing
mountpoint as root: a stray in `./plugins` that `instance-b` then fails to
load, or a `/data/plugin_data` PocketMine cannot write in. `selftest.sh`
fails on either.

`*.phar` is gitignored by the repo root's `.gitignore`, and
`RiftalMines.config.yml` by this folder's own, since a copy rendered by hand
carries a real database password. Three config files are tracked:
`RiftalMines.config.yml.template`, and `RiftalRanks.config.yml` and
`RiftalEconomy.config.yml`, which hold no password because each login's
comes from the environment (see below).

## Build `RiftalMines.phar` and `contracts.phar`

`contracts.phar` lands one level up, at the top of `plugins/`, because every
instance loads it beside `RiftalAccounts` (`../../README.md`,
`RiftalAccounts`), whose recipe there builds the same file.

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
for pkg in mines lib contracts; do
  mkdir -p "$BUILD/$pkg"
  cp -r "$GAME/$pkg/." "$BUILD/$pkg/"
done

docker run --rm \
  -v "$BUILD:/build" -v "$PWD/..:/out" \
  -v /tmp/pharynx.phar:/pharynx.phar:ro -v /tmp/composer.phar:/composer.phar:ro \
  -w /build -e COMPOSER_ALLOW_SUPERUSER=1 -e HOME=/tmp \
  local-pocketmine-mp sh -c '
    set -e
    for pair in contracts:contracts mines:instance-only/RiftalMines; do
      cd "/build/${pair%%:*}"
      php /composer.phar install --prefer-dist --no-interaction --no-progress --no-dev
      sh /out/instance-only/link-replaced.sh
      php -dphar.readonly=0 /pharynx.phar -i . -c "-p=/out/${pair#*:}.phar"
    done
  '
```

`contracts.phar` is named after its folder, as
`riftal-game/.github/scripts/packages.sh` names every phar it builds;
PocketMine loads a plugin by its `plugin.yml` name, `RiftalContracts`, not
by file name. `contracts/` has to be copied even for `RiftalMines.phar`
alone: `mines` and `lib` both name `../contracts` as a Composer path
repository, so `composer install` stops without it, although `--no-dev`
keeps its classes out of `RiftalMines.phar`. Those classes load once, from
`contracts.phar`, so every plugin fires and hears the same events.

Building from a copy of `mines/`, `lib/` and `contracts/`, not a bind mount,
keeps `composer install`'s `vendor/` out of a working tree another lane may have
open. Under `wslc`, translate the `-v` and `-w` flags as `/dev-stack` does.

`link-replaced.sh` is the step that lets a `mines` pinned to the fork,
`axolotl-pm/pocketmine-mp`, build at all; riftal-game pins it since
riftal-game#566. libasynql requires `pocketmine/pocketmine-mp`, which the fork
only replaces, and pharynx reads a virion's requires by name, so without the
link it stops at `Failed to read file
./vendor/pocketmine/pocketmine-mp/composer.json`. Where no virion requires a
replaced name, as in `contracts`, it links nothing.

Confirm each build holds a `plugin.yml`, the same check
`riftal-game/.github/scripts/packages.sh`'s `phar_one()` runs on every phar it
builds:

```sh
for phar in ../contracts RiftalMines; do
  docker run --rm -v "$PWD/$phar.phar:/p.phar:ro" local-pocketmine-mp php -r '
    foreach (new RecursiveIteratorIterator(new Phar("/p.phar")) as $f) {
      if (basename((string) $f) === "plugin.yml") { exit(0); }
    }
    fwrite(STDERR, "no plugin.yml found inside the built phar\n");
    exit(1);
  ' || echo "$phar.phar is broken"
done
```

A `RiftalMines.phar` that was never built is skipped without a word (see
below), so this check, or reading `Loading RiftalContracts` then `Loading
RiftalMines` in the boot log, is the only way to catch a boot that silently
never had the plugin at all. A missing `contracts.phar` is not skipped:
`require-accounts.sh` stops every instance's boot before PocketMine starts,
naming the file, because PocketMine itself would log `Unknown dependency:
RiftalContracts` and force-shut the whole server down.

## The config override

With `RiftalMines.phar` present, `start-instance.sh` runs `render-config.sh`
on every boot, writing the template to
`/data/plugin_data/RiftalMines/config.yml` with the container's own
`MYSQL_ROOT_PASSWORD`. Compose passes `instance` the same `images/.env` value
it passes `mysql`, so the two cannot disagree; a `wslc run` of `instance`
needs `-e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"` for the same reason.
Unset, the boot stops before PocketMine starts and names the variable. No
file rendered into this folder is read.

## `RiftalRanks` and the `ranks` login

`RiftalRanks.phar` loads on `instance` alone, like `RiftalMines`
(riftal-infra#558), so `instance-b` is given no `ranks` login. Build it with
the recipe above, `ranks` in place of `mines` in the copy loop and
`ranks:instance-only/RiftalRanks` in place of the `mines` pair. `ranks` names
`../contracts` as a Composer path repository too, so `contracts/` is copied
either way. It declares `depend: [RiftalContracts]`, met by the
`contracts.phar` at the top of `plugins/`, which `require-accounts.sh`
refuses to boot without.

It connects as the `ranks` login of ADR 008, never as root. With the phar
present, `start-instance.sh` copies `RiftalRanks.config.yml` to
`/data/plugin_data/RiftalRanks/config.yml` on every boot. That file differs
from the shipped one only in its schema, `riftal_dev`, and carries no
password: `DatabaseSettings` reads it from `RIFTAL_DB_PASSWORD_RANKS`, which
compose passes `instance` from `images/.env`. A `wslc run` of `instance`
needs `-e RIFTAL_DB_PASSWORD_RANKS` for the same reason. Unset, the boot
stops before PocketMine starts and names the variable.

The login itself is made by the migration runner, not by the instance. Run it
before `instance`, with `grants.sql` mounted and
`-e RIFTAL_DB_PASSWORD_RANKS` exported from the same `images/.env`, as
`../../../migrations/README.md` shows under "Running it locally". The runner
creates `ranks`, grants it `riftal_role_ranks`, and resets its password to
that value on every run, so after editing it in `images/.env` run the
runner again before the next boot. A grant `ranks` lacks surfaces on this
stack as ERROR 1142, which is the point.

## `RiftalEconomy` and the `economy` login

`RiftalEconomy.phar`, the sell shop and the balance ledger, loads on
`instance` alone the same way (riftal-infra#887). The recipe above stops
on it at pharynx, `Failed to read file
./vendor/pocketmine/pocketmine-mp/composer.json`, because nothing links the
package `axolotl-pm/pocketmine-mp` replaces. Build it the way riftal-game's
CI does instead: in the same container, with the same copies of `lib/`,
`contracts/` and `economy/` and a Composer on `PATH` as `composer`, run
`bash packages.sh phar /build /pharynx.phar /out` from riftal-game's
`.github/scripts/`, then move `/out/economy.phar` to
`instance-only/RiftalEconomy.phar`. It declares `depend: [RiftalContracts]` and `softdepend: [RiftalCustody]`, both
met at the top of `plugins/`.

Everything said of `ranks` above holds with `economy` in its place:
`start-instance.sh` copies `RiftalEconomy.config.yml` to
`/data/plugin_data/RiftalEconomy/config.yml` on every boot, the file differs
from the shipped one only in its schema, the password comes from
`RIFTAL_DB_PASSWORD_ECONOMY`, the boot stops naming it when it is unset, and
the migration runner provisions `economy` with `riftal_role_economy`. Its
sell locations come from the `world_index.json` `deliver-world-index.sh`
puts in the same folder.

## Why an override is required, not optional

`mines/resources/config.yml`'s shipped default (`host: riftal-mysql, schema:
riftal, username: mines`) matches nothing on this stack under compose: the
`mysql` service sets no `container_name`, so on `riftal-dev` it answers to
`mysql` and not to `riftal-mysql` (checked 2026-10-06 with `getent hosts` on
a throwaway compose network of the same shape), the database compose creates
is `riftal_dev`, and no `mines` MySQL user has ever been provisioned here.
Under the `wslc run` form, the database container is named `riftal-mysql`
on `riftal-dev` and is started with `--network-alias mysql`, which is meant
to make it answer to `mysql` as the compose service does. Whether either
name resolves there has not been checked (riftal-infra#265). The template
names `mysql` for compose.

Loading the phar without this override does not fail the plugin alone:
`RiftalGames\Lib\Database\ConnectionProvider::open()` in `Main::onEnable()`
connects synchronously, so a `SqlError` there is uncaught and takes the
whole server down within 4 seconds of boot (verified
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
in `./plugins`. That boot predates riftal-game#294, which logs the `lumber`
line as a WARNING, so a clean boot with the phar carries no ERROR line. This
README records no boot since that change.

## `lumber` and the shared MySQL row

`MineWorldLoader` (riftal-game#49) logs and skips a world with no folder on
disk instead of crashing, so loading `RiftalMines.phar` before the `lumber`
world exists in `riftal-world` is safe: the log carries one WARNING line,
`mines: registered world "lumber" has no world folder to load yet; skipping
until the map builder produces one`, and the plugin otherwise enables
normally. It is a warning because a boot log check fails on any ERROR line
(riftal-game#294). A `worlds/lumber` folder that exists but will not load,
such as an interrupted build with no `level.dat`, is a fault and is logged
as an ERROR. Land the built world
under `riftal-world`'s `worlds/lumber` once `riftal-game`'s DesignBridge
plugin exposes the write ops `build_mine --apply` needs (`create_world`,
`pregen`, `set_blocks`/`fill`; tracked under riftal-game's `lane:bridge`
issues, riftal-infra#239 and riftal-game#8) to turn
that log line into a loaded world.
