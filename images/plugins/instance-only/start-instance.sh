#!/bin/bash
# The `instance` service's command in images/compose.yaml. PocketMine loads
# plugins from one flat directory and /plugins is the ./plugins bind
# instance-b shares, so this instance's roster is assembled in the
# container's own disposable filesystem: every plugin at the top of /plugins,
# plus RiftalMines.phar, RiftalRanks.phar and RiftalEconomy.phar once built.
# It mounts nothing and runs as uid 1000, so /data/plugin_data on a fresh
# volume stays writable by PocketMine.
#
# Everything else mirrors the image's start-pocketmine (pmmp-core
# docker/start.sh), which instance-b runs and which cannot be reused here
# because it hard-codes --plugins=/plugins. selftest.sh pins this copy of
# that behaviour, and check-start-sh.sh fails CI when the image's start.sh is
# not the version recorded in start-sh.sha256, so a change there is noticed
# but still has to be carried here by hand.
set -euo pipefail
shopt -s nullglob

mapfile -t unowned < <(find /data /plugins ! -user pocketmine)
if [ "${#unowned[@]}" -gt 0 ]; then
	echo "=== WARNING ==="
	echo "Detected ${#unowned[@]} files in /data or /plugins not owned by the user \"pocketmine\"!"
	echo "For example:"
	printf '%s\n' "${unowned[@]:0:10}"
	echo "This may cause problems when running the server."
	echo "If you mount /data and /plugins from a local directory, consider running \`chown -R 1000:1000 \$MOUNT\` (replace \$MOUNT with your local directory) (you may need sudo to run this)"
	echo "==============="
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
roster="$(mktemp -d)"
shared=(/plugins/*.php /plugins/*.phar)
if [ "${#shared[@]}" -gt 0 ]; then
	cp "${shared[@]}" "$roster/"
fi

# A source folder loads only through DevTools.phar's FolderPluginLoader, which
# takes a directory holding plugin.yml and src/. Copying it whether or not
# DevTools is present loads it here exactly when instance-b would. -L because
# PocketMine follows a symlink where a copied link might dangle.
for dir in /plugins/*/; do
	if [ -e "${dir}plugin.yml" ] && [ -d "${dir}src" ]; then
		cp -RL "${dir%/}" "$roster/"
	fi
done

# POCKETMINE_PLUGINS is "Name[:version] ...", fetched from Poggit when not
# already in /plugins. The download lands in the roster, not /plugins, so
# this instance never writes into the directory instance-b loads from.
# Split on every whitespace, newlines included, as core's unquoted expansion
# does; read -d '' reports failure at end of input, which is expected.
read -ra poggit -d '' <<<"${POCKETMINE_PLUGINS:-}" || true
for plugin in "${poggit[@]}"; do
	IFS=: read -r name version _ <<<"$plugin"
	if [ ! -f "$roster/$name.phar" ]; then
		echo "Installing $name:$version from Poggit"
		wget -O "$roster/$name.phar" "https://poggit.pmmp.io/get/$name/$version"
	fi
done

if [ -f "$here/RiftalMines.phar" ]; then
	# RiftalMines declares depend: [RiftalContracts]. contracts.phar sits at
	# the top of /plugins, already in the roster, and require-accounts.sh has
	# stopped the boot before this script runs when it is not built.
	#
	# The plugin's bundled config names a schema this stack does not have,
	# and it connects on enable, so a wrong config or a refused login takes
	# the whole server down. The mines login's password comes only from
	# RIFTAL_DB_PASSWORD_MINES (ADR 008), so its absence is named here,
	# before PocketMine starts.
	if [ -z "${RIFTAL_DB_PASSWORD_MINES:-}" ]; then
		echo "start-instance.sh: RiftalMines.phar is built and RIFTAL_DB_PASSWORD_MINES is not set; the instance takes it from images/.env" >&2
		exit 1
	fi
	mkdir -p /data/plugin_data/RiftalMines
	bash "$here/render-config.sh" /data/plugin_data/RiftalMines/config.yml
	cp "$here/RiftalMines.phar" "$roster/"
fi

if [ -f "$here/RiftalRanks.phar" ]; then
	# RiftalRanks declares depend: [RiftalContracts], met by contracts.phar
	# as for RiftalMines above.
	#
	# Without the variable the plugin connects with the config's empty
	# password, MySQL refuses it, and PocketMine shuts the whole server down
	# because a plugin failed to enable. Stopping here names the cause.
	if [ -z "${RIFTAL_DB_PASSWORD_RANKS:-}" ]; then
		echo "start-instance.sh: RiftalRanks.phar is built and RIFTAL_DB_PASSWORD_RANKS is not set; the instance takes it from images/.env" >&2
		exit 1
	fi
	mkdir -p /data/plugin_data/RiftalRanks
	cp "$here/RiftalRanks.config.yml" /data/plugin_data/RiftalRanks/config.yml
	cp "$here/RiftalRanks.phar" "$roster/"
fi

if [ -f "$here/RiftalEconomy.phar" ]; then
	# RiftalEconomy declares depend: [RiftalContracts], met by contracts.phar
	# as for RiftalMines above, and fails its enable without a password for
	# the same reason as RiftalRanks.
	if [ -z "${RIFTAL_DB_PASSWORD_ECONOMY:-}" ]; then
		echo "start-instance.sh: RiftalEconomy.phar is built and RIFTAL_DB_PASSWORD_ECONOMY is not set; the instance takes it from images/.env" >&2
		exit 1
	fi
	mkdir -p /data/plugin_data/RiftalEconomy
	cp "$here/RiftalEconomy.config.yml" /data/plugin_data/RiftalEconomy/config.yml
	cp "$here/RiftalEconomy.phar" "$roster/"
fi

cd /opt/pocketmine
read -ra pm_args <<<"${POCKETMINE_ARGS:-}"

# Colour by default only on a real TTY, so a captured log stays greppable.
ansi_args=()
if [ "${POCKETMINE_ANSI:-auto}" = "1" ] || { [ "${POCKETMINE_ANSI:-auto}" = "auto" ] && [ -t 1 ]; }; then
	ansi_args=(--enable-ansi)
fi

exec php PocketMine-MP.phar --no-wizard "${ansi_args[@]}" --data=/data --plugins="$roster" "${pm_args[@]}"
