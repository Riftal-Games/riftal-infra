#!/bin/bash
# Runs ahead of each instance's start script: copies designer/world_index.json,
# mounted read-only at /etc/riftal, into the data folder of every plugin that
# reads it, then execs the command it was given. The index names worlds and
# never instances, so every instance gets the same file and a split changes no
# map data (riftal-infra#293). Copying on every boot keeps the deploy's index
# the one a plugin reads, never a copy left on the volume by an earlier boot.
set -euo pipefail

index=/etc/riftal/world_index.json
if [ ! -f "$index" ]; then
	echo "$index is not mounted; RiftalRanks and RiftalRiots cannot enable without it" >&2
	exit 1
fi

for plugin in RiftalRanks RiftalRiots; do
	mkdir -p "/data/plugin_data/$plugin"
	cp "$index" "/data/plugin_data/$plugin/world_index.json"
done

exec "$@"
