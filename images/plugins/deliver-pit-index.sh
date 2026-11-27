#!/bin/bash
# Runs ahead of each instance's start script: checks designer/pit/, mounted
# read-only at /etc/riftal/pit, against the sha256 manifest it carries, then
# copies pit_index.json and the 14 mine position sets into the data folder of
# every plugin that reads them, and execs the command it was given. Any file
# that is missing or differs stops the boot here, naming it, so no instance
# starts on a set that is not the one the level was built with (riftal-infra#1507).
# Every plugin gets every file: the index and the sets are identical on every
# instance, and a split changes no map data.
set -euo pipefail

src=/etc/riftal/pit
manifest="$src/pit.sha256"
if [ ! -f "$manifest" ]; then
	echo "$manifest is not mounted; RiftalMines, RiftalCustody, RiftalRanks and RiftalCells have no pit index to read from their data folders" >&2
	exit 1
fi

files=(pit_index.json)
for layer in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
	files+=("mine_sets/layer_$layer.bin")
done

for file in "${files[@]}"; do
	if ! grep -q "^[0-9a-f]\{64\}  $file\$" "$manifest"; then
		echo "$file is not named in $manifest" >&2
		exit 1
	fi
done

if ! report=$(cd "$src" && sha256sum --check --quiet "$manifest" 2>&1); then
	echo "pit files differ from $manifest:" >&2
	echo "$report" >&2
	exit 1
fi

for plugin in RiftalMines RiftalCustody RiftalRanks RiftalCells; do
	mkdir -p "/data/plugin_data/$plugin/mine_sets"
	for file in "${files[@]}"; do
		cp "$src/$file" "/data/plugin_data/$plugin/$file"
	done
done

exec "$@"
