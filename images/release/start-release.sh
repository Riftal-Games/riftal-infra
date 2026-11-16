#!/bin/bash
# The release image's start command. It assembles the instance's plugin roster
# from /opt/riftal/plugins and hands PocketMine that roster alone, so no phar
# in /plugins or in a reused /plugins volume is ever loaded, and the image tag
# decides which build runs.
#
# RiftalCustody, RiftalAccounts and contracts load on every instance. The
# instance adds RiftalMines, RiftalRanks, RiftalEconomy, RiftalGangs,
# RiftalRiots, RiftalPlots and RiftalAnvil by naming them in RIFTAL_PLUGINS,
# separated by spaces or commas. Each plugin's config goes to /data/plugin_data
# on every boot with the database host and schema from RIFTAL_DB_HOST and
# RIFTAL_DB_SCHEMA. The password of each plugin's login comes only from
# RIFTAL_DB_PASSWORD_<PLUGIN> (ADR 008) and a missing one stops the boot here,
# because a plugin that fails to enable takes the whole server down.
# RiftalAnvil has no login and no config.
#
# RiftalGangs, RiftalRiots and RiftalPlots read the designer's index of the
# map from their data folder, and Gangs and Riots refuse to enable without it.
# The instance mounts it at /etc/riftal/world_index.json, the path the dev
# stack uses, and a roster that names one of them with no such file stops the
# boot here. The index names levels and never instances, so every instance
# mounts the same one.
#
# /data is untouched until every check has passed.
#
# Every script plugin in SCRIPTS loads on every instance, and a missing one
# stops the boot. It gates itself on the instance's flags.
set -euo pipefail

ROOT=/opt/riftal
ALWAYS=(RiftalCustody RiftalAccounts contracts)
OPTIONAL=(RiftalMines RiftalRanks RiftalEconomy RiftalGangs RiftalRiots RiftalPlots RiftalAnvil)
NO_LOGIN=(RiftalAnvil)
INDEXED=(RiftalGangs RiftalRiots RiftalPlots)
INDEX=/etc/riftal/world_index.json
SCRIPTS=(RiftalDownstreamLimit.php)

refuse() {
	echo "start-release.sh: $1" >&2
	exit 1
}

for var in RIFTAL_DB_HOST RIFTAL_DB_SCHEMA; do
	if ! [[ "${!var:-}" =~ ^[A-Za-z0-9._-]+$ ]]; then
		refuse "$var is unset or not letters, digits, dots, hyphens and underscores"
	fi
done

selected=()
read -ra requested <<<"$(tr , ' ' <<<"${RIFTAL_PLUGINS:-}")"
for name in "${requested[@]}"; do
	if [[ " ${OPTIONAL[*]} " != *" $name "* ]]; then
		refuse "RIFTAL_PLUGINS names $name; the choices are ${OPTIONAL[*]}"
	fi
	selected+=("$name")
done

with_login=(RiftalAccounts)
indexed=()
for name in "${selected[@]}"; do
	if [[ " ${NO_LOGIN[*]} " != *" $name "* ]]; then
		with_login+=("$name")
	fi
	if [[ " ${INDEXED[*]} " == *" $name "* ]]; then
		indexed+=("$name")
	fi
done
for name in "${with_login[@]}"; do
	var="RIFTAL_DB_PASSWORD_${name#Riftal}"
	var="${var^^}"
	if [ -z "${!var:-}" ]; then
		refuse "$name is in this instance's roster and $var is not set"
	fi
done

if [ "${#indexed[@]}" -gt 0 ] && { [ ! -f "$INDEX" ] || [ ! -s "$INDEX" ] || [ ! -r "$INDEX" ]; }; then
	refuse "${indexed[*]} in this instance's roster read the index and $INDEX is not a readable, non-empty file"
fi

read -ra pm_args <<<"${POCKETMINE_ARGS:-}"
for arg in "${pm_args[@]}"; do
	case "$arg" in
	--plugins | --plugins=* | --data | --data=*)
		refuse "POCKETMINE_ARGS carries $arg; the roster and /data are set here"
		;;
	esac
done

roster="$(mktemp -d)"
for name in "${ALWAYS[@]}" "${selected[@]}"; do
	if [ ! -s "$ROOT/plugins/$name.phar" ]; then
		refuse "$ROOT/plugins/$name.phar is missing from this image"
	fi
	cp "$ROOT/plugins/$name.phar" "$roster/"
done
for name in "${SCRIPTS[@]}"; do
	if [ ! -s "$ROOT/plugins/$name" ]; then
		refuse "$ROOT/plugins/$name is missing from this image"
	fi
	cp "$ROOT/plugins/$name" "$roster/"
done
(cd "$roster" && sha256sum -- *.phar *.php | sed 's/^/roster /')

for name in "${with_login[@]}"; do
	mkdir -p "/data/plugin_data/$name"
	sed \
		-e "s/^  host: .*/  host: \"$RIFTAL_DB_HOST\"/" \
		-e "s/^  schema: .*/  schema: \"$RIFTAL_DB_SCHEMA\"/" \
		"$ROOT/plugin_data/$name/config.yml" >"/data/plugin_data/$name/config.yml"
done

for name in "${indexed[@]}"; do
	mkdir -p "/data/plugin_data/$name"
	cp "$INDEX" "/data/plugin_data/$name/world_index.json"
done

cd /opt/pocketmine

ansi_args=()
if [ "${POCKETMINE_ANSI:-auto}" = "1" ] || { [ "${POCKETMINE_ANSI:-auto}" = "auto" ] && [ -t 1 ]; }; then
	ansi_args=(--enable-ansi)
fi

exec php PocketMine-MP.phar --no-wizard "${ansi_args[@]}" --data=/data --plugins="$roster" "${pm_args[@]}"
