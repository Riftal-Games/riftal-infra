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
| `RIFTAL_DEV_ENV` | `plugins/RiftalDevBots.php`'s second admission signal, independent of `--riftal-dev-bots` and `xbox-auth`. Fixed to `1` in `compose.yaml` itself, not read from `.env`, because it marks the dev stack shape and is never something an operator tunes. No production deploy path may set it (riftal-infra#113). |

The full production `/add-instance` runbook already exists as a skill; this
table exists so the mechanism (env var, not mounted config) is written down
somewhere editable in a normal PR.
