# images/

The local dev stack (`compose.yaml`) and the plugins mounted into it. See
`/dev-stack` for the runbook.

## Instance environment variables

Set in `images/.env`, copied from `.env.example`. Never commit `.env`.

| Variable | Purpose |
|---|---|
| `INSTANCE_BIND` | Host interface the instance publishes `19132/udp` on. Defaults to `127.0.0.1`. |
| `INSTANCE_ID` | This instance's identity, read by `RiftalGames\Lib\InstanceIdentity::fromEnvironment()` in riftal-game's shared lib and tagged onto every shared-database row the instance writes. No safe default exists across a split, which is why the class throws rather than guess one; the dev stack's single instance ships `dev-1` in `.env.example` so the boot has something to read. When an instance is split out under `/add-instance`, its `INSTANCE_ID` is set the same way, as a container env var, never written into mounted `server.properties` or `pocketmine.yml`. |

The full production `/add-instance` runbook already exists as a skill; this
table exists so the mechanism (env var, not mounted config) is written down
somewhere editable in a normal PR.
