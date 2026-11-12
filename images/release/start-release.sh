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
#
# Every script plugin in SCRIPTS loads on every instance, and a missing one
# stops the boot. It gates itself on the instance's flags.
#
# The image delivers its own world index and levels (ADR 043). Before /data is
# written the boot refuses a /etc/riftal that does not match the digest list the
# image carries, a RIFTAL_LEVEL_ZONES zone the list lacks, and any value of
# RIFTAL_LEVEL_ZONES and POCKETMINE_ARGS that level-args.sh, the rule CI applies
# to every instance definition, finds fault with. It then delivers the index and
# seeds the zones with the scripts in /opt/riftal/boot. No variable skips any of
# these steps.
#
# The image also carries RiftalGangs, RiftalRiots, RiftalPlots and RiftalAnvil.
# The dev stack's start scripts give them no login and no config, so none is
# offered here.
set -euo pipefail

ROOT=/opt/riftal
ALWAYS=(RiftalCustody RiftalAccounts contracts)
OPTIONAL=(RiftalMines RiftalRanks RiftalEconomy)
SCRIPTS=(RiftalDownstreamLimit.php)
BOOT=$ROOT/boot
DIGESTS=$BOOT/etc-riftal.sha256
LEVELS=/etc/riftal/levels

refuse() {
	echo "start-release.sh: $1" >&2
	exit 1
}

# $1 a level manifest. Prints its content_sha256, nothing when it holds none.
content_sha256() {
	sed -n 's/^ *"content_sha256": *"\([0-9a-f]\{64\}\)",\{0,1\} *$/\1/p' "$1" 2>/dev/null || true
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

if [ ! -f "$BOOT/level-args.sh" ]; then
	refuse "$BOOT/level-args.sh is missing from this image"
fi
# shellcheck source=../plugins/level-args.sh
. "$BOOT/level-args.sh"

if ! out="$(sha256sum -c --quiet "$DIGESTS" 2>&1)"; then
	refuse "/etc/riftal is not what this image delivers, so $DIGESTS does not check: $out"
fi

if ! findings="$(level_findings "${RIFTAL_LEVEL_ZONES-}" "${POCKETMINE_ARGS-}")"; then
	while IFS= read -r line; do
		echo "start-release.sh: $line" >&2
	done <<<"$findings"
	exit 1
fi

read -ra zones <<<"$RIFTAL_LEVEL_ZONES"
for zone in "${zones[@]}"; do
	if ! awk -v want="$LEVELS/$zone/level-manifest.json" '$2 == want { found = 1 } END { exit !found }' "$DIGESTS"; then
		refuse "RIFTAL_LEVEL_ZONES lists $zone and this image carries no level $zone"
	fi
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

for zone in "${zones[@]}"; do
	if [ -e "/data/worlds/$zone" ]; then
		seeded="$(content_sha256 "/data/worlds/$zone/level-manifest.json")"
		tag_sha="$(content_sha256 "$LEVELS/$zone/level-manifest.json")"
		if [ "$seeded" != "$tag_sha" ]; then
			echo "LEVEL DIFFERS $zone seeded=${seeded:-none} tag=$tag_sha"
		fi
	fi
done

"$BOOT/deliver-world-index.sh" || refuse "deliver-world-index.sh failed"
"$BOOT/seed-levels.sh" || refuse "seed-levels.sh failed"

cd /opt/pocketmine

ansi_args=()
if [ "${POCKETMINE_ANSI:-auto}" = "1" ] || { [ "${POCKETMINE_ANSI:-auto}" = "auto" ] && [ -t 1 ]; }; then
	ansi_args=(--enable-ansi)
fi

exec php PocketMine-MP.phar --no-wizard "${ansi_args[@]}" --data=/data --plugins="$roster" "${pm_args[@]}"
