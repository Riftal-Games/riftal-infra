#!/bin/bash
# Runs ahead of each instance's start script: copies designer/world_index.json,
# mounted read-only at /etc/riftal, into the data folder of every plugin that
# consumes it, then execs the command it was given. The index names worlds and
# never instances, so every instance gets the same file and a split changes no
# map data (riftal-infra#293). RiftalRanks and RiftalRiots read their bundled
# resources/world_index.json until riftal-game#208 points them at their data
# folder; from then this copy is the one they read. RiftalEconomy bundles none:
# its sell shop reads its sell locations from this copy alone (spec 003).
# RiftalMines bundles none either: with join_teleport switched on it reads the
# join location from this copy alone and rejects every join if it is missing
# (spec 006). It loads on instance only, so on instance-b the copy sits unread.
# RiftalGangs bundles none: it finds the contested mine in this copy alone and
# refuses to enable if it is missing (riftal-game#328).
# Copying on every boot keeps each copy the deploy's index, never one left on
# the volume by an earlier boot.
set -euo pipefail

index=/etc/riftal/world_index.json
if [ ! -f "$index" ]; then
	echo "$index is not mounted; RiftalRanks, RiftalRiots, RiftalEconomy, RiftalMines and RiftalGangs have no deployed world index to read from their data folders" >&2
	exit 1
fi

for plugin in RiftalRanks RiftalRiots RiftalEconomy RiftalMines RiftalGangs; do
	mkdir -p "/data/plugin_data/$plugin"
	cp "$index" "/data/plugin_data/$plugin/world_index.json"
done

exec "$@"
