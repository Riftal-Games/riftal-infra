#!/bin/bash
# Writes RiftalMines.config.yml.template to $1. start-instance.sh runs it on
# every boot, so a config left on the volume by any earlier boot, including
# one that carried a password, is replaced by the template as it stands. The
# template holds no secret: the mines login's password reaches the plugin
# only through RIFTAL_DB_PASSWORD_MINES in the environment (ADR 008).
set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "usage: render-config.sh <output path>" >&2
	exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$DIR/RiftalMines.config.yml.template" "$1"
