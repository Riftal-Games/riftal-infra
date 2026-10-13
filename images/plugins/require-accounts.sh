#!/bin/bash
# Runs ahead of require-custody.sh on every instance, stops the boot when
# RiftalAccounts cannot load, then puts its config on the instance's own
# volume and execs the command it was given. RiftalAccounts is the only writer
# of the accounts table, and every instance that runs a game plugin resolves
# logins through it (steward rulings on riftal-game#176 and riftal-infra#465).
# Every instance loads RiftalCustody, a game plugin, so the check holds on
# every instance whatever else its roster carries, at the top of /plugins or
# in instance-only/. Both phars sit at the top of /plugins, so each roster
# picks them up the way it picks up RiftalCustody.phar.
set -euo pipefail

refuse() {
	echo "require-accounts.sh: $1; see images/README.md, RiftalAccounts" >&2
	exit 1
}

if [ ! -s /plugins/RiftalAccounts.phar ]; then
	refuse "/plugins/RiftalAccounts.phar is not built, and every instance loads it"
fi
# RiftalAccounts declares depend: [RiftalContracts], as RiftalMines does, and
# PocketMine shuts the server down after loading when a dependency is missing.
if [ ! -s /plugins/contracts.phar ]; then
	refuse "/plugins/contracts.phar is not built, and RiftalAccounts depends on it"
fi
# Without the variable the plugin connects with the config's empty password,
# MySQL refuses it, and PocketMine shuts the whole server down because a
# plugin failed to enable.
if [ -z "${RIFTAL_DB_PASSWORD_ACCOUNTS:-}" ]; then
	refuse "RIFTAL_DB_PASSWORD_ACCOUNTS is not set; the instance takes it from images/.env"
fi

mkdir -p /data/plugin_data/RiftalAccounts
cp /plugins/RiftalAccounts.config.yml /data/plugin_data/RiftalAccounts/config.yml

exec "$@"
