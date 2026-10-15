# images/

The local dev stack (`compose.yaml`) and the plugins mounted into it. See
`/dev-stack` for the runbook, and `../docs/dev-stack-two-instance.md` for the
`instance-b` bring-up steps pending manual folding into that skill.

## Instance environment variables

Set in `images/.env`, copied from `.env.example`. Never commit `.env`.

| Variable | Purpose |
|---|---|
| `INSTANCE_BIND` | Host interface the instance publishes `19132/udp` on. Defaults to `127.0.0.1`. |
| `INSTANCE_ID` | This instance's identity, read by `RiftalGames\Lib\InstanceIdentity::fromEnvironment()` in riftal-game's shared lib and tagged onto every shared-database row the instance writes. No safe default exists across a split, which is why the class throws rather than guess one; the dev stack's single instance ships `dev-1` in `.env.example` so the boot has something to read. When an instance is split out under `/add-instance`, its `INSTANCE_ID` is set the same way, as a container env var, never written into mounted `server.properties` or `pocketmine.yml`. |
| `INSTANCE_B_BIND`, `INSTANCE_B_ID` | The same two settings for `instance-b`, the second core instance `compose.yaml` defines alongside `instance` to prove the instance-split shape on one shared MySQL (riftal-infra#6). Distinct names because both instances read a container env var literally named `INSTANCE_ID`; the `_B` suffix is only how `.env` tells them apart before substitution. |
| `BACKUP_RETENTION`, `BACKUP_INTERVAL_SECONDS`, `PARTIAL_MAX_AGE_MINUTES`, `LOCK_MAX_AGE_MINUTES` | How many backup sets `../deploy/backup.sh` keeps, how often the `backup` service runs it, how old a leftover `.partial` must be before it sweeps it, and how old a held `.lock` must be before it presumes the lock abandoned and sweeps that too. See `../deploy/README.md`. |
| `RIFTAL_DB_PASSWORD_BACKUP` | Password of `backup`, the login the `backup` service dumps with. The `dump-login` service runs `../migrations/run-migrations.sh` with it on every `docker compose up`, creating or rotating the login, and `backup` starts only once that run succeeds. Empty or unset, `dump-login` exits 1 naming the variable and `backup` never starts. `dump-login-selftest.sh` proves both. See `../deploy/README.md`. |
| `RIFTAL_DB_PASSWORD_ACCOUNTS` | The `accounts` MySQL login's password (ADR 008). The migration runner provisions the login with it, and compose hands it to both instances, where `RiftalAccounts` reads it from the environment, never from its config. At least 24 characters, `[A-Za-z0-9]` only. See RiftalAccounts below. |
| `RIFTAL_DEV_ENV` | `plugins/RiftalDevBots.php`'s second admission signal, independent of `--riftal-dev-bots` and `xbox-auth`. Fixed to `1` in `compose.yaml` itself, not read from `.env`, because it marks the dev stack shape and is never something an operator tunes. No production deploy path may set it (riftal-infra#113). `plugins/RiftalDevFaults.php` exists under the same gate, or not at all. It is also reserved at wipe time: see Reserved for the dev stack, below. |

## Reserved for the dev stack

Two values belong to the shared dev stack (`compose.yaml`) alone. No alpha,
production or rig stack uses either:

- The database name `riftal_dev`, which `compose.yaml` fixes as
  `MYSQL_DATABASE` on exactly three services: `mysql`, `backup` and
  `dump-login`.
- `RIFTAL_DEV_ENV=1` in the environment of a wipe run
  (`../deploy/wipe.sh`), on top of the instances' own `RIFTAL_DEV_ENV`
  above.

The reservation is a standing rule. It exists for the wipe's dev path, which
riftal-infra#1110 is to build to the steward rulings on riftal-pm#1312 and
riftal-pm#1314. A wipe runs as a one-off container that cannot see the
instances' environment, so that path takes two keys, both required, each
matched exactly: `RIFTAL_DEV_ENV=1` in the wipe's own environment, and a
`MYSQL_DATABASE` of `riftal_dev` that exists on the target server. The two
keys gate every wipe that clears a level with no build, default or
non-default. With both, such a level is cleared: afterwards core generates a
default level fresh on the next boot, and a non-default level is left absent.
Any other combination refuses the wipe, `RIFTAL_DEV_ENV=1` against another
database included. One key alone never takes the path, but a stack outside
the shared dev stack carrying either value is one key away from it, and the
ruling reverses if one does.

Rigs name their database `riftal` and never run a wipe, so a wipe aimed at
one refuses. The one other place `riftal_dev` may appear is
riftal-infra#1110's selftest, which creates it in throwaway `mysql:8`
containers as a fixture for the script, not a stack the wipe serves.

## Dev faults

`plugins/RiftalDevFaults.php` breaks a running dev instance on purpose, for
ADR 017 P8 (riftal-infra#932). From the server console only:

- `devfaults-flush-fail <player>` cancels every save of that player until the
  process ends, so custody sees the player's flush fail.
- `devfaults-probe-fail` makes `players/.custody-probe` an empty directory, so
  custody's probe fails too and it kills the process. The next boot removes
  the directory before `RiftalCustody` enables, so the restart is not killed
  by custody's own boot probe. A boot without the gate leaves it there, and
  custody stops that boot.
- `devfaults-chunk-save-fail <level> <chunkX> <chunkZ>` fails the next
  durable save of that chunk, for ADR 030 (riftal-infra#1124). `<level>` is
  the level's folder name and must be loaded on this instance, and the chunk
  coordinates are integers. The fault is single-use and keyed on the level
  and chunk: the first matching `DurableChunkSaveEvent` is cancelled, logged
  as `cancelled the durable save of chunk <chunkX> <chunkZ> in <level>`, and
  the fault is gone. A save of any other chunk is untouched. An armed fault
  whose chunk is never saved stays armed until the process ends, so read the
  cancel line rather than assume it was spent. The command exists only when
  `RiftalContracts` is loaded with `DurableChunkSaveEvent`; without it the
  boot logs that the command is not registered and the other two still are.

## Dev bots tile contents

`plugins/RiftalDevBots.php` registers `devbots-tile <x> <y> <z> [level]`
under the same gate, for ADR 025 P5 and spec 020's M3 criteria
(riftal-infra#1105). From the console or an admitted dev bot, it logs a
container tile's server-side contents one slot a line, each with the item's
Bedrock id, meta and count, and the first line with the server tick. A bot
also gets the lines in chat. It reads only, and reports a chunk nothing holds
loaded rather than loading it.

## Dev bots test hooks

Spec 020 criteria 22 to 24 (riftal-infra#1124) take two more commands from
`plugins/RiftalDevBots.php`, under the same gate and from the console or an
admitted dev bot:

- `devbots-autosave <on|off> [level]` sets one level's autosave, as
  `save-off` does for every level, and logs the level, the tick and the result.
- `devbots-shulker <bot>` hands an admitted dev bot a shulker box holding one
  stick. It makes an item, which hard rule 1 forbids everywhere else, so it
  gives to nobody but an admitted dev bot.

Criterion 23's failed player save is `devfaults-flush-fail` above, and its
failed durable chunk save is `devfaults-chunk-save-fail` above.

## The world index

`instance` and `instance-b` both mount `../designer/world_index.json`
read-only at `/etc/riftal/world_index.json` and start through
`plugins/deliver-world-index.sh`, which copies it to
`/data/plugin_data/RiftalRanks/`, `/data/plugin_data/RiftalRiots/`,
`/data/plugin_data/RiftalEconomy/` and `/data/plugin_data/RiftalMines/` on every
boot, as uid 1000, before handing over to the instance's own start script.
The designer file is the deploy's index. RiftalRanks and RiftalRiots also bundle a
`resources/world_index.json` and read that one until riftal-game#208 switches
them to their data folder; from then the delivered copy is what they read.
RiftalEconomy bundles none; its sell shop reads the delivered copy.
RiftalMines bundles none either; its join teleport, once
`join_teleport.enabled` is on, reads the delivered copy and rejects every join
without it. RiftalMines loads on `instance` alone, so on `instance-b` that copy
sits unread. It
names worlds, never instances, so every instance gets the same one and a split
changes no map data. An
instance started without the mount stops before PocketMine does, naming the
path. A `wslc run` of either instance needs the same `-v` and command.

## Restarts

Both instances run `restart: on-failure` with no retry cap, start through
`plugins/restart/boot-gate.sh`, and are healthchecked by
`plugins/restart/raknet-ping.php` (riftal-infra#355). A crash restarts. A clean
`stop` exits 0 and stays down. A start that waits on core's `server.lock`
while a backup holds a stopped volume exits 1 at core's lock check and is
started again, as ADR 015 item 6 expects, unless it was the third of three
starts each under 120 s apart, when the gate parks it. A deploy that cannot boot fails
within seconds, and after three starts each under 120 s apart the gate stops starting
PocketMine and parks the container Up and `unhealthy`, logging this line:

```
RIFTAL BOOT LOOP: 3 starts each under 120 s apart, PocketMine not started, container parked
```

Read the earlier boots in the same log, fix the cause, then restart the
container, or replace it, which starts with no start times at all. A restart
within 120 s of the last start parks again. `/dev-stack`'s `wslc run` lines
carry none of the three yet.

## RiftalCustody

Every instance loads riftal-game's `custody` plugin, `RiftalCustody`, which
keeps item entities out of every chunk save and players out of tiles (ADR 013,
riftal-pm `docs/decisions/013-item-yielding-entities-are-never-saved.md`).
It sits at the top of `plugins/`, so `start-instance.sh` copies it into
each instance's roster, `instance-b`'s through `plugins/instance-b/start.sh`. Both
instances start through `plugins/require-custody.sh`, after the world index
delivery and `require-accounts.sh`. It stops the boot before PocketMine when
`plugins/RiftalCustody.phar` is missing or empty. The phar is gitignored, so
build it once per clone, and again when `custody` or `lib` changes, with
riftal-game's own CI script, which links the fork for pharynx and checks the
phar holds a `plugin.yml`:

```sh
GAME=../../riftal-game
BUILD=$(mktemp -d) OUT=$(mktemp -d)
git -C "$GAME" archive origin/main custody lib .github/scripts/packages.sh | tar -x -C "$BUILD"
curl -fsSLo "$BUILD/pharynx.phar" \
  https://github.com/SOF3/pharynx/releases/download/0.3.8/pharynx.phar
echo "de84964df51d595a9d521ee42df010cf6e817b1e5ceef17de6ef884c41b28133  $BUILD/pharynx.phar" | sha256sum -c -
curl -fsSLo "$BUILD/composer-setup.php" https://getcomposer.org/installer

docker run --rm -m 2g --cpus 2 --user "$(id -u):$(id -g)" -v "$BUILD:/build" -v "$OUT:/out" \
  -e COMPOSER_ALLOW_SUPERUSER=1 -e HOME=/tmp --entrypoint bash local-pocketmine-mp -c '
    mkdir -p /tmp/bin
    php /build/composer-setup.php --install-dir=/tmp/bin --filename=composer --quiet
    PATH=/tmp/bin:$PATH bash /build/.github/scripts/packages.sh phar /build /build/pharynx.phar /out
  '
cp "$OUT/custody.phar" plugins/RiftalCustody.phar
```

`custody` is the only folder in that copy with a `plugin.yml`, so it is the
one phar built. `lib` rides along shaded in. `--user` lets the container write
into the two `mktemp` directories, which only their owner can open.

A boot's LOADS verdict, P13 included, is read from its log, never from an exit
code:

```sh
docker compose logs --no-color --no-log-prefix instance > /tmp/instance.log
bash loads-check.sh /tmp/instance.log
```

It fails unless the log reaches `Done (`, holds no line above `WARNING`, and
shows `Enabling RiftalCustody` before the first `Preparing world`. Run it on a
log captured after `stop` and it also catches a plugin left enabled past
`RiftalCustody` at shutdown, which `RiftalCustody` logs as an `ERROR`. Every
script plugin here lists `@softdepend RiftalCustody` in its header for that
reason, and `custody-selftest.sh` fails on one that does not.

The full production `/add-instance` runbook already exists as a skill; this
table exists so the mechanism (env var, not mounted config) is written down
somewhere editable in a normal PR.

## RiftalAccounts

`RiftalAccounts` resolves every login to its account and is the only writer
of the `accounts` table, so every instance that runs a game plugin loads it
(steward rulings on riftal-game#176 and riftal-infra#465). `RiftalCustody` is
one, so that is every instance. `RiftalAccounts.phar` and `contracts.phar`,
which it declares `depend: [RiftalContracts]` on, sit at the top of
`plugins/` beside `RiftalCustody.phar`, so both rosters pick them up. Both
instances start through `plugins/require-accounts.sh`, after the world index
delivery. It stops the boot before PocketMine, naming the cause, when either
phar or `RIFTAL_DB_PASSWORD_ACCOUNTS` is missing, whatever other game plugins
the instance carries.

Build both with the `RiftalCustody` recipe above, adding `accounts contracts`
to the `git archive` paths, then:

```sh
cp "$OUT/accounts.phar" plugins/RiftalAccounts.phar
cp "$OUT/contracts.phar" plugins/contracts.phar
```

It connects as the `accounts` login of ADR 008, never as root.
`require-accounts.sh` copies `plugins/RiftalAccounts.config.yml` to
`/data/plugin_data/RiftalAccounts/config.yml`, on the instance's own volume,
on every boot. That file differs from the shipped one only in its schema,
`riftal_dev`, and carries no password: `DatabaseSettings` reads it from
`RIFTAL_DB_PASSWORD_ACCOUNTS`, which compose passes both instances from
`images/.env`. A `wslc run` of either instance needs
`-e RIFTAL_DB_PASSWORD_ACCOUNTS` and the same command chain.

The login itself is made by the migration runner, not by an instance. Run it
before either instance, with `grants.sql` mounted and
`-e RIFTAL_DB_PASSWORD_ACCOUNTS` exported from the same `images/.env`, as
`../migrations/README.md` shows under "Running it locally". The runner
creates `accounts`, grants it `riftal_role_accounts` and nothing else, and
resets its password to that value on every run, so after editing it in
`images/.env` run the runner again before the next boot. Booted before that,
the plugin logs `Access denied for user 'accounts'` and PocketMine shuts the
server down.
