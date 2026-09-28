#!/bin/bash
# Substitutes MYSQL_ROOT_PASSWORD into RiftalMines.config.yml.template and
# writes the result next to it, gitignored, never the template itself.
# Run after sourcing images/.env and before starting `instance`; rerun
# whenever .env's password changes, same as re-sourcing .env itself.
set -euo pipefail

if [ -z "${MYSQL_ROOT_PASSWORD:-}" ]; then
	echo "render-config.sh: MYSQL_ROOT_PASSWORD is not set; source images/.env first" >&2
	exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sed "s/__MYSQL_ROOT_PASSWORD__/$MYSQL_ROOT_PASSWORD/" "$DIR/RiftalMines.config.yml.template" > "$DIR/RiftalMines.config.yml"
