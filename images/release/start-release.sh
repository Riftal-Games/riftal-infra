#!/bin/bash
# The release image's start command. It assembles the instance's plugin roster
# from /opt/riftal/plugins and hands PocketMine that roster alone, so no phar
# in /plugins or in a reused /plugins volume is ever loaded, and the image tag
# decides which build runs.
#
# RiftalCustody, RiftalAccounts and contracts load on every instance. The
# instance adds RiftalMines, RiftalRanks and RiftalEconomy by naming them in
# RIFTAL_PLUGINS, separated by spaces or commas. Each plugin's config goes to
# /data/plugin_data on every boot with the database host and schema from
# RIFTAL_DB_HOST and RIFTAL_DB_SCHEMA. The password of each plugin's login
# comes only from RIFTAL_DB_PASSWORD_<PLUGIN> (ADR 008) and a missing one stops
# the boot here, because a plugin that fails to enable takes the whole server
# down. /data is untouched until every check has passed.
set -euo pipefail

ROOT=/opt/riftal
ALWAYS=(RiftalCustody RiftalAccounts contracts)
OPTIONAL=(RiftalMines RiftalRanks RiftalEconomy)

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

with_login=(RiftalAccounts "${selected[@]}")
for name in "${with_login[@]}"; do
	var="RIFTAL_DB_PASSWORD_${name#Riftal}"
	var="${var^^}"
	if [ -z "${!var:-}" ]; then
		refuse "$name is in this instance's roster and $var is not set"
	fi
done

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
(cd "$roster" && sha256sum -- *.phar | sed 's/^/roster /')

for name in "${with_login[@]}"; do
	mkdir -p "/data/plugin_data/$name"
	sed \
		-e "s/^  host: .*/  host: \"$RIFTAL_DB_HOST\"/" \
		-e "s/^  schema: .*/  schema: \"$RIFTAL_DB_SCHEMA\"/" \
		"$ROOT/plugin_data/$name/config.yml" >"/data/plugin_data/$name/config.yml"
done

cd /opt/pocketmine

ansi_args=()
if [ "${POCKETMINE_ANSI:-auto}" = "1" ] || { [ "${POCKETMINE_ANSI:-auto}" = "auto" ] && [ -t 1 ]; }; then
	ansi_args=(--enable-ansi)
fi

exec php PocketMine-MP.phar --no-wizard "${ansi_args[@]}" --data=/data --plugins="$roster" "${pm_args[@]}"
