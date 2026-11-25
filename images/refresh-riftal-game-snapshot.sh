#!/usr/bin/env bash
# Copies riftal-game's shipped mines, ranks, accounts, economy, plots and gangs
# configs from the checkout in $1 into images/riftal-game-snapshot and records
# the commit in SOURCE. Run it in the same PR as the riftal-infra template change that
# follows a riftal-game config change, then run
# plugins/instance-only/selftest.sh, which compares the template to the copy.
# Refuses a checkout with uncommitted changes to those files, so SOURCE names
# the commit the copy really came from.
set -euo pipefail

game="${1:?usage: refresh-riftal-game-snapshot.sh <riftal-game checkout>}"
dest="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/riftal-game-snapshot"
plugins=(mines ranks accounts economy plots gangs)

paths=()
for plugin in "${plugins[@]}"; do
  paths+=("$plugin/resources/config.yml")
  [ -f "$game/$plugin/resources/config.yml" ] || { printf 'no %s/resources/config.yml under %s\n' "$plugin" "$game" >&2; exit 1; }
done
sha="$(git -C "$game" rev-parse HEAD)"
if [ -n "$(git -C "$game" status --porcelain -- "${paths[@]}")" ]; then
  printf 'uncommitted changes in %s: commit them first so SOURCE names a real commit\n' "$game" >&2
  exit 1
fi
for plugin in "${plugins[@]}"; do
  mkdir -p "$dest/$plugin/resources"
  cp "$game/$plugin/resources/config.yml" "$dest/$plugin/resources/config.yml"
done
printf '%s\n' "$sha" > "$dest/SOURCE"
printf 'snapshot taken from riftal-game %s\n' "$sha"
