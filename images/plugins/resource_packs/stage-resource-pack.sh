#!/bin/bash
# Stages the instance's resource pack into its data folder:
#
#   stage-resource-pack.sh <resource_packs directory of the data folder>
#
# The pack and resource_packs.yml come from the directory this script sits in
# and go to the given one on every boot. The source is checked against
# bbstudio_RP.mcpack.sha256 first, and any difference stops the boot before
# anything is written, so a client is never sent a pack that is not the one
# committed. Files are installed, not copied over, because the source files are
# read-only in the release image and a copy of a read-only file would not be
# writable on the next boot.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${1:?usage: stage-resource-pack.sh <resource_packs directory of the data folder>}"

for file in bbstudio_RP.mcpack bbstudio_RP.mcpack.sha256 resource_packs.yml; do
	if [ ! -s "$here/$file" ]; then
		echo "stage-resource-pack.sh: $here/$file is missing or empty" >&2
		exit 1
	fi
done

if ! (cd "$here" && sha256sum --check --status bbstudio_RP.mcpack.sha256); then
	echo "stage-resource-pack.sh: $here/bbstudio_RP.mcpack differs from bbstudio_RP.mcpack.sha256" >&2
	exit 1
fi

mkdir -p "$dest"
install -m 0644 "$here/bbstudio_RP.mcpack" "$dest/bbstudio_RP.mcpack"
install -m 0644 "$here/resource_packs.yml" "$dest/resource_packs.yml"
