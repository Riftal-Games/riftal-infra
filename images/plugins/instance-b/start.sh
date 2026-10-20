#!/bin/bash
# The `instance-b` service's command in images/compose.yaml. instance-b loads
# RiftalEconomy, so a sale made on its plots settles against the same shared
# balance ledger as one made on `instance` (spec 017 criterion 20, ADR 022,
# riftal-infra#348). RiftalMines and RiftalRanks serve `instance`'s worlds
# alone and stay off it.
#
# start-instance.sh loads whichever of RiftalMines, RiftalRanks and
# RiftalEconomy sit beside it, on top of every plugin at the top of /plugins.
# A copy staged in this container's own filesystem with RiftalEconomy alone
# beside it gives instance-b that roster, with the same config copy and the
# same refusal of a missing RIFTAL_DB_PASSWORD_ECONOMY as `instance`, and
# writes nothing into the ./plugins bind both instances share.
set -euo pipefail

only=/plugins/instance-only
staged="$(mktemp -d)"
cp "$only/start-instance.sh" "$staged/"
if [ -f "$only/RiftalEconomy.phar" ]; then
	cp "$only/RiftalEconomy.phar" "$only/RiftalEconomy.config.yml" "$staged/"
fi
exec bash "$staged/start-instance.sh"
