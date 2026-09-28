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

# The template holds the password in a double-quoted YAML string, where these
# two characters are syntax.
case "$MYSQL_ROOT_PASSWORD" in
	*'"'* | *'\'*)
		echo 'render-config.sh: MYSQL_ROOT_PASSWORD holds " or \, which the YAML string cannot carry as is' >&2
		exit 1
		;;
esac

# A bash substitution, not sed, so / and & in the password stay literal. The
# quotes around the replacement keep bash 5.2's patsub_replacement from
# reading & as the matched text.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$(cat "$DIR/RiftalMines.config.yml.template")"
printf '%s\n' "${template//__MYSQL_ROOT_PASSWORD__/"$MYSQL_ROOT_PASSWORD"}" > "$DIR/RiftalMines.config.yml"
