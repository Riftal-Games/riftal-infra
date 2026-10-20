# dev-stack: the second instance, `instance-b`

This content belongs in `.claude/skills/dev-stack/SKILL.md`, in the same place
as the rest of the bring-up steps, replacing that file's unfilled "Two
instances" checklist. It lives here instead because no agent in this
environment can edit a `SKILL.md` file: the tool permission layer declines
the edit outright regardless of what this repo's own `.claude/settings.json`
or agent definitions say. **A human needs to fold this into
`.claude/skills/dev-stack/SKILL.md` by hand.**

Three corrections to the current SKILL.md text:

1. The "Bring it up" section's opening line still reads "one core
   `instance`". Since riftal-infra#129, `images/compose.yaml` defines two:
   `instance` and `instance-b`, same image tag, sharing the one `mysql`
   service. The line should say so.
2. The "Two instances" section is an unfilled checklist with no concrete
   command, unlike the hand-translated `wslc run` commands already given for
   `mysql` and `instance`. The command below is that translation, verified by
   QA against a running `riftal-mysql` and `riftal-instance` as part of
   riftal-infra#129's review (PR #129, QA comment, 2026-09-27): both
   instances reached `Done (`, distinct `INSTANCE_ID` confirmed via `wslc
   inspect`, distinct worlds confirmed in the boot log (`Preparing world
   "mine_a"` vs `Preparing world "plots_b"`), and a RakNet ping against each
   published port answered with a distinct MOTD on the same protocol number.
3. Step 4, "Instance", creates `riftal-instance` without
   `--auto-report.enabled=0`, so a crash in that container uploads its dump
   to the core image's crash archive. Every PocketMine service in
   `images/compose.yaml` and `designer/stack/compose.yaml` passes the flag
   (riftal-infra#232). Only `0` turns reporting off: the flag's value is a
   raw string cast with `(bool)`, and `(bool) "false"` is `true`. Step 4's
   `POCKETMINE_ARGS` line should read:

   ```sh
     -e "POCKETMINE_ARGS=--level-name=mine_a --level-type=normal --xbox-auth=false --motd=riftal-dev --riftal-dev-bots=on --auto-report.enabled=0" \
   ```

   A `riftal-instance` container created without the flag reports crashes
   until it is recreated: `stop` on stdin, wait for the shutdown line, remove,
   and a fresh `wslc run` against the same `riftal-world` volume.

## 5. Second instance (`instance-b`)

Run this alongside the primary instance from step 4, on the same
`riftal-dev` network and against the same `riftal-mysql`. Nothing here
starts a second database: `instance-b` reaches the one `mysql` service the
same way `instance` does, by network alias.

`INSTANCE_B_BIND` and `INSTANCE_B_ID` come from `images/.env`, same
loopback-by-default rule as `INSTANCE_BIND`. Re-source the `.env` block from
the top of this runbook if either was just edited.

```sh
wslc run -d -i --name riftal-instance-b --network riftal-dev \
  --memory 2G --cpus 2 \
  -p "${INSTANCE_B_BIND:-127.0.0.1}:19133:19132/udp" \
  -v riftal-world-b:/data -v "$INFRA/images/plugins:/plugins" \
  -v "$INFRA/designer/world_index.json:/etc/riftal/world_index.json:ro" \
  -e "INSTANCE_ID=${INSTANCE_B_ID}" \
  -e "RIFTAL_DEV_ENV=1" \
  -e "RIFTAL_DB_PASSWORD_ACCOUNTS=${RIFTAL_DB_PASSWORD_ACCOUNTS}" \
  -e "RIFTAL_DB_PASSWORD_ECONOMY=${RIFTAL_DB_PASSWORD_ECONOMY}" \
  -e "RIFTAL_DB_PASSWORD_PLOTS=${RIFTAL_DB_PASSWORD_PLOTS}" \
  -e "POCKETMINE_ARGS=--level-name=plots_b --level-type=flat --xbox-auth=false --motd=riftal-dev-b --riftal-dev-bots=on --auto-report.enabled=0" \
  local-pocketmine-mp bash /plugins/restart/boot-gate.sh \
  bash /plugins/deliver-world-index.sh bash /plugins/require-accounts.sh \
  bash /plugins/require-custody.sh bash /plugins/instance-b/start.sh

wslc logs riftal-instance-b
```

This mirrors `images/compose.yaml`'s `instance-b` service definition
except for its `restart: on-failure` policy and RakNet healthcheck, which this
`wslc run` does not carry (riftal-infra#578), and CI fails when the two
disagree on any flag (`.github/scripts/wslc-drift.sh`): same image tag, `19133/udp` published instead of `19132/udp`
(the container still listens on `19132` internally, `19133` is only where the
host maps it), its own volume `riftal-world-b` instead of `riftal-world`,
its own `INSTANCE_ID` value from `INSTANCE_B_ID` instead of `INSTANCE_ID`,
and a distinct world and generator (`plots_b`/`flat`, against the primary
instance's `mine_a`/`normal`) so the split is exercised against two genuinely
different worlds rather than one world cloned onto a second port.
`RIFTAL_DEV_ENV=1` is the same on both: `images/plugins/RiftalDevBots.php`
admits bots only with it set, alongside `--riftal-dev-bots=on` and
`--xbox-auth=false`, so an `instance-b` created without it refuses every bot.
The command chain is the same as compose's too, `boot-gate.sh` first, though
with no restart policy behind it the gate never sees a second start:
`require-custody.sh` stops the
boot before PocketMine when `images/plugins/RiftalCustody.phar` is missing or
empty, so build it first (`images/README.md`, RiftalCustody), and
`require-accounts.sh` does the same for `RiftalAccounts.phar`,
`contracts.phar` and `RIFTAL_DB_PASSWORD_ACCOUNTS` (`images/README.md`,
RiftalAccounts). `images/plugins/instance-b/start.sh` loads
`RiftalEconomy.phar` and `RiftalPlots.phar` from
`images/plugins/instance-only/` once built, and then stops the boot without
`RIFTAL_DB_PASSWORD_ECONOMY` or `RIFTAL_DB_PASSWORD_PLOTS`, as on `instance`.
`plots_b` is not the `plots` level, so `instance-b` hosts no plot grid; spec
017 criterion 4 has a claim there written to the shared database, teleporting
nobody.

- [ ] The log reaches `Done (` for `riftal-instance-b`, same checks as the
      primary instance in step 4: no `[.../CRITICAL]`, `[.../EMERGENCY]`,
      `[.../ALERT]` or `[.../ERROR]` line, `Online mode is disabled` present.
- [ ] `wslc inspect riftal-instance-b` shows `INSTANCE_ID=dev-2` (or whatever
      `INSTANCE_B_ID` was set to), distinct from the primary instance's
      `dev-1`.
- [ ] The boot log shows `Preparing world "plots_b"`, not `mine_a`.
- [ ] A RakNet ping against `19133` answers with a distinct MOTD
      (`riftal-dev-b`) from the primary instance's `riftal-dev` on `19132`,
      same protocol number.
- [ ] A write made against one instance's shared-database rows is visible
      from a separate connection, proving both instances reach the same
      `mysql`, not a copy each. There is no gameplay plugin that writes a
      shared row yet (riftal-infra#129), so this is exercised directly at
      the database level: insert a row tagged one instance's `INSTANCE_ID`
      from one `mysql` client connection, read it back from a second,
      independent connection. Use a throwaway table only, and drop it
      afterward.

Tear down the same way as the primary instance (`wslc stop -t 60
riftal-instance-b`, confirm the shutdown log line and exit code 0, then
`wslc remove riftal-instance-b`). `riftal-world-b` is a named volume, same
rule as `riftal-world`: leave it, removing it is a reset and never the
routine ending.
