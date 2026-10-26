# instance-only plugins

Plugins the `instance` service loads and `instance-b` loads only in part
(`../../compose.yaml`). `RiftalDevBots.php` one level up is a single script
both instances want; `RiftalMines` is not, because it resets the worlds
`instance` hosts and no others. `RiftalEconomy` is wanted on both
(riftal-infra#348), so `instance-b` takes it from here and nothing else.

Both instances see this folder through the shared `./plugins` bind, and
PocketMine never loads from a subfolder. `instance-b` runs
`../instance-b/start.sh`, which stages a copy of `start-instance.sh` in the
container's own filesystem with `RiftalEconomy.phar` and its config alone
beside it, so the rest of this folder never reaches its roster.
`instance` runs `start-instance.sh` instead of the image's `start-pocketmine`:
it assembles its plugin roster in the container's own disposable filesystem
and renders the config onto the volume as uid 1000. Both instances run it, and
it otherwise does what `start-pocketmine` does: the ownership warning,
every plugin a loader takes from the top of `./plugins`, `POCKETMINE_PLUGINS`
from Poggit (into the roster, never `./plugins`) and `POCKETMINE_ANSI`. That
includes a source folder holding `plugin.yml` and `src/`, which only a
`DevTools.phar` loads (`../../../designer/stack/README.md`); without one, it
is copied and ignored on both instances alike. `start-pocketmine`
hard-codes `--plugins=/plugins`, so it cannot be reused. `selftest.sh` pins
this script's copy of that behaviour. `check-start-sh.sh` hashes the image's
`start-pocketmine` (core's `docker/start.sh`) and fails CI when it is not
the version recorded in `start-sh.sha256`; carry the change into
`start-instance.sh` by hand, then record the new hash and pmmp-core commit.
`boot-selftest.sh` boots the pinned core image with the script as it ships,
with the phar unbuilt, built with no password, and built with one. Nothing is
bind-mounted inside `/plugins` or `/data`, because Docker creates a missing
mountpoint as root: a stray in `./plugins` that `instance-b` then fails to
load, or a `/data/plugin_data` PocketMine cannot write in. `selftest.sh`
fails on either.

`*.phar` is gitignored by the repo root's `.gitignore`, and
`RiftalMines.config.yml` by this folder's own, so a copy edited by hand to
hold a database password is never committed. Three config files are tracked:
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

## The copy `rig.js` reads

riftal-pm's `devtools/rig.js` takes its phars from this folder unless
`RIFTAL_RIG_PHARS` names another, and finds each plugin, and each plugin it
`depend`s on, as `<plugin.yml name>.phar`. A `softdepend` is not followed.
The rigs in `devtools/rigs/` load `RiftalMines`, `RiftalRanks`,
`RiftalEconomy` and `RiftalAccounts`, and all four depend on
`RiftalContracts`. The recipes above write the first three here under
their plugin names. The other two land one level up, at the top of
`plugins/`: `contracts.phar` from the recipe above, and
`RiftalAccounts.phar` from the `RiftalAccounts` recipe in
`../../README.md`. A rig that loads either refuses to start until a copy
sits here under the plugin's name:

```sh
cp ../contracts.phar RiftalContracts.phar
cp ../RiftalAccounts.phar RiftalAccounts.phar
```

`start-instance.sh` copies only `RiftalMines.phar`, `RiftalRanks.phar` and
`RiftalEconomy.phar` into the roster, so `instance` still loads
`RiftalContracts` and `RiftalAccounts` once each, from the top of
`plugins/`.

Rebuild `RiftalMines.phar`, `RiftalRanks.phar`, `RiftalEconomy.phar`,
`contracts.phar` and `RiftalAccounts.phar` whenever riftal-game's `main`
moves past them, then run both `cp` lines again. Every top-level phar a rig
loads has to be copied in again after each rebuild, because a rig reads
only the copy here: a phar older than its plugin's resources fails at
enable, as a `RiftalMines.phar` built before `quarry` was registered does
with `cannot read registered ... resource quarry.json` (riftal-infra#1062).

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
`instance` (riftal-infra#887) and on `instance-b` (riftal-infra#348), whose
chest shops settle against the same ledger, so both are given the `economy`
login from the same `images/.env` value. Build it with the recipe
above, `economy` in place of `mines` in the copy loop and
`economy:instance-only/RiftalEconomy` in place of the `mines` pair. Like
`mines`, it pins `axolotl-pm/pocketmine-mp`, so `link-replaced.sh` is what
gets it past pharynx. It declares `depend: [RiftalContracts]` and
`softdepend: [RiftalCustody]`, both met at the top of `plugins/`.

Everything said of `ranks` above holds with `economy` in its place:
`start-instance.sh` copies `RiftalEconomy.config.yml` to
`/data/plugin_data/RiftalEconomy/config.yml` on every boot, the file differs
from the shipped one only in its schema, the password comes from
`RIFTAL_DB_PASSWORD_ECONOMY` on either instance, the boot stops naming it
when it is unset, and
the migration runner provisions `economy` with `riftal_role_economy`. Its
sell locations come from the `world_index.json` `deliver-world-index.sh`
puts in the same folder.

## Why an override is required, not optional

`mines/resources/config.yml`'s shipped default (`host: mysql, schema:
riftal, username: mines`) names a schema this stack does not have: the
database compose creates is `riftal_dev`. The `mysql` service sets no
`container_name`, so on `riftal-dev` it answers to `mysql` and not to
`riftal-mysql` (checked 2026-10-06 with `getent hosts` on a throwaway compose
network of the same shape). Under the `wslc run` form, the database container
is named `riftal-mysql` on `riftal-dev` and is started with `--network-alias mysql`, which is meant
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
as an ERROR.

A built `lumber` reaches `worlds/lumber` through `../seed-levels.sh`
(ADR 009 item 5), not by hand. For each zone in `RIFTAL_LEVEL_ZONES` whose
folder is absent from `/data/worlds`, it checks the file tree mounted
read-only at `/etc/riftal/levels/<zone>` against the `level-manifest.json` at
that folder's root, copies it into a temporary directory on the volume as the
server's user, and renames it into place. It never touches a folder that
exists, and it exits non-zero, before PocketMine starts, on a missing source or
a failed check. `compose.yaml` does not run it yet (riftal-infra#1324), so
`instance` still boots without the folder and logs that line. The build that fills that
source is `designer level build`, which needs the DesignBridge ops `pregen`
and `scan_items`. `seed-levels-selftest.sh` boots the pinned core image with
the step ahead of PocketMine.
