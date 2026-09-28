#!/bin/bash
# The `instance` service's command in images/compose.yaml. PocketMine loads
# plugins from one flat directory and /plugins is the ./plugins bind
# instance-b shares, so this instance's roster is assembled in the
# container's own disposable filesystem: every plugin at the top of /plugins,
# plus RiftalMines.phar once built. It mounts nothing and runs as uid 1000,
# so /data/plugin_data on a fresh volume stays writable by PocketMine.
#
# Everything else mirrors the image's start-pocketmine (pmmp-core
# docker/start.sh), which instance-b runs and which cannot be reused here
# because it hard-codes --plugins=/plugins. Keep the two in step;
# selftest.sh holds this side to it.
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

# POCKETMINE_PLUGINS is "Name[:version] ...", fetched from Poggit when not
# already in /plugins. The download lands in the roster, not /plugins, so
# this instance never writes into the directory instance-b loads from.
read -ra poggit <<<"${POCKETMINE_PLUGINS:-}"
for plugin in "${poggit[@]}"; do
	IFS=: read -r name version _ <<<"$plugin"
	if [ ! -f "$roster/$name.phar" ]; then
		echo "Installing $name:$version from Poggit"
		wget -O "$roster/$name.phar" "https://poggit.pmmp.io/get/$name/$version"
	fi
done

if [ -f "$here/RiftalMines.phar" ]; then
	# The plugin's bundled config names a database nothing here resolves, and
	# it connects on enable, so without the rendered one the whole server dies.
	if [ ! -f "$here/RiftalMines.config.yml" ]; then
		echo "start-instance.sh: RiftalMines.phar is built but RiftalMines.config.yml is not rendered; run render-config.sh" >&2
		exit 1
	fi
	cp "$here/RiftalMines.phar" "$roster/"
	mkdir -p /data/plugin_data/RiftalMines
	cp "$here/RiftalMines.config.yml" /data/plugin_data/RiftalMines/config.yml
fi

cd /opt/pocketmine
read -ra pm_args <<<"$POCKETMINE_ARGS"

# Colour by default only on a real TTY, so a captured log stays greppable.
ansi_args=()
if [ "${POCKETMINE_ANSI:-auto}" = "1" ] || { [ "${POCKETMINE_ANSI:-auto}" = "auto" ] && [ -t 1 ]; }; then
	ansi_args=(--enable-ansi)
fi

exec php PocketMine-MP.phar --no-wizard "${ansi_args[@]}" --data=/data --plugins="$roster" "${pm_args[@]}"
