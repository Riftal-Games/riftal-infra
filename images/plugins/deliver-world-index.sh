#!/bin/bash
# Runs ahead of each instance's start script: copies designer/world_index.json,
# mounted read-only at /etc/riftal, into the data folder of every plugin that
# consumes it, then execs the command it was given. The index names worlds and
# never instances, so every instance gets the same file and a split changes no
# map data (riftal-infra#293). RiftalRanks and RiftalRiots bundle none: Ranks
# gates mine entry and finds its rank-up markers in this copy, Riots reads its
# safe zones from it, and each refuses to enable if it is missing.
# RiftalEconomy bundles none either: its sell shop reads its sell locations
# from this copy alone (spec 003).
# RiftalMines bundles none either: with join_teleport switched on it reads the
# join location from this copy alone and rejects every join if it is missing
# (spec 006). It loads on instance only, so on instance-b the copy sits unread.
# RiftalGangs bundles none: it finds the contested mine in this copy alone and
# refuses to enable if it is missing (riftal-game#328).
# RiftalPlots reads its plots_grid region from this copy (riftal-game#1657).
# Copying on every boot keeps each copy the deploy's index, never one left on
# the volume by an earlier boot. The release image's index is mode 0444 and cp
# keeps the mode, so -f replaces the read-only copy the previous boot left.
set -euo pipefail

index=/etc/riftal/world_index.json
if [ ! -f "$index" ]; then
	echo "$index is not mounted; RiftalRanks, RiftalRiots, RiftalEconomy, RiftalMines, RiftalGangs and RiftalPlots have no deployed world index to read from their data folders" >&2
	exit 1
fi

for plugin in RiftalRanks RiftalRiots RiftalEconomy RiftalMines RiftalGangs RiftalPlots; do
	mkdir -p "/data/plugin_data/$plugin"
	cp -f "$index" "/data/plugin_data/$plugin/world_index.json"
done

exec "$@"
