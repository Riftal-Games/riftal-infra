#!/bin/bash
# The `instance` service's command in images/compose.yaml. PocketMine loads
# plugins from one flat directory and /plugins is the ./plugins bind
# instance-b shares, so this instance's roster is assembled in the
# container's own disposable filesystem: every plugin at the top of /plugins,
# plus RiftalMines.phar once built. It mounts nothing and runs as uid 1000,
# so /data/plugin_data on a fresh volume stays writable by PocketMine.
set -euo pipefail
shopt -s nullglob

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
roster="$(mktemp -d)"
shared=(/plugins/*.php /plugins/*.phar)
if [ "${#shared[@]}" -gt 0 ]; then
	cp "${shared[@]}" "$roster/"
fi

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
exec php PocketMine-MP.phar --no-wizard --data=/data --plugins="$roster" "${pm_args[@]}"
