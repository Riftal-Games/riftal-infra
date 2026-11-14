#!/bin/bash
# Runs ahead of each instance's start script: puts every zone in
# RIFTAL_LEVEL_ZONES (space separated, unset for none) on /data/worlds before
# PocketMine starts, then execs the command it was given (ADR 009 item 5).
#
# /etc/riftal/levels/<zone>, mounted read-only, is the level folder itself with
# level-manifest.json at its root. A zone is seeded only when /data/worlds/<zone>
# is absent; a folder that exists is never touched. Otherwise the source's file
# tree is checked against the manifest, copied into a temporary directory under
# /data/worlds, checked again, and renamed into place, so the zone's folder is
# either absent or complete. A temporary directory a killed run left behind is
# removed, and logged, on the next boot.
#
# A source that is missing, has no readable manifest, holds anything but regular
# files and directories, or fails the check stops the boot here. A server
# started without the folder would generate the zone as its default world, and
# the first rule would then keep that terrain on every later boot.
#
# The tree hash is sha256 over `sha256sum`'s output for every regular file but
# the root manifest, as paths without a leading ./ sorted bytewise: the same
# bytes designer/designer/level_engine.py's read_tree hashes. A path holding a
# backslash or a newline makes sha256sum escape its output, so it fails the
# check instead of matching.
#
# RIFTAL_LEVELS_DIR and RIFTAL_WORLDS_DIR move the two directories for a caller
# that is not an instance boot: deploy/wipe-volumes.sh seeds each instance
# volume's worlds/ from the build's output folders. Run as root, it refuses
# unless RIFTAL_SEED_CHOWN names the <uid>:<gid> that should own what is seeded.
set -euo pipefail

levels="${RIFTAL_LEVELS_DIR:-/etc/riftal/levels}"
worlds="${RIFTAL_WORLDS_DIR:-/data/worlds}"
manifest=level-manifest.json

say() { printf 'seed-levels: %s\n' "$*"; }
refuse() {
	printf 'seed-levels: %s\n' "$*" >&2
	exit 1
}

tree_sha256() {
	(
		cd "$1"
		find . -type f ! -path "./$manifest" -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum -- | sha256sum | cut -d' ' -f1
	)
}

# $1 the manifest, $2 the key. Prints the one hex digest the build wrote on its
# own line, nothing when the key is missing or repeated.
manifest_digest() {
	local found
	found="$(sed -n "s/^ *\"$2\": *\"\\([0-9a-f]\\{64\\}\\)\",\\{0,1\\} *\$/\\1/p" "$1")"
	if [ "$(printf '%s' "$found" | grep -c .)" -eq 1 ]; then
		printf '%s' "$found"
	fi
}

tmp=
cleanup() {
	if [ -n "$tmp" ]; then
		rm -rf -- "$tmp"
	fi
}
trap cleanup EXIT

# A killed run leaves its .seed-<zone>.XXXXXX behind. A zone name cannot start
# with a dot, so no zone folder can match the pattern; only a directory that
# does is removed.
clear_leftovers() {
	local dir
	[ -d "$worlds" ] || return 0
	while IFS= read -r -d '' dir; do
		if [[ "${dir##*/}" =~ ^\.seed-[A-Za-z0-9_-]+\.[A-Za-z0-9]{6}$ ]]; then
			chmod -R u+rwX -- "$dir"
			rm -rf -- "$dir"
			say "removed leftover temporary directory $dir"
		fi
	done < <(find "$worlds" -mindepth 1 -maxdepth 1 -type d -name '.seed-*' -print0)
}

seed_zone() {
	local zone="$1" source="$levels/$1" dest="$worlds/$1" want content odd

	if [[ ! "$zone" =~ ^[A-Za-z0-9_-]+$ ]]; then
		refuse "zone \"$zone\" is not a plain name; letters, digits, _ and - only"
	fi
	if [ -e "$dest" ] || [ -L "$dest" ]; then
		say "$zone present at $dest; nothing seeded"
		return
	fi
	if [ ! -d "$source" ]; then
		refuse "$zone is not in $worlds and its level source $source is not mounted; build volume riftal_smoke_level_$zone with \`designer level build $zone\` and mount it read-only there"
	fi
	want="$(manifest_digest "$source/$manifest" tree_sha256)"
	content="$(manifest_digest "$source/$manifest" content_sha256)"
	if [ -z "$want" ] || [ -z "$content" ]; then
		refuse "$zone: $source/$manifest is missing or holds no single tree_sha256 and content_sha256 line; volume riftal_smoke_level_$zone was never fully built, run \`designer level build $zone\`"
	fi
	odd="$(find "$source" ! -type f ! -type d -print -quit)"
	if [ -n "$odd" ]; then
		refuse "$zone: $odd is neither a regular file nor a directory"
	fi
	if [ "$(tree_sha256 "$source")" != "$want" ]; then
		refuse "$zone: the file tree of $source is not the one $manifest names ($want)"
	fi

	mkdir -p "$worlds"
	tmp="$(mktemp -d "$worlds/.seed-$zone.XXXXXX")"
	cp -R "$source/." "$tmp/"
	chmod -R u+rwX "$tmp"
	if [ "$(tree_sha256 "$tmp")" != "$want" ]; then
		refuse "$zone: the copy of $source does not hash to $want"
	fi
	if [ -n "${RIFTAL_SEED_CHOWN:-}" ]; then
		chown -R "$RIFTAL_SEED_CHOWN" "$tmp"
	fi
	if [ -e "$dest" ] || [ -L "$dest" ]; then
		refuse "$zone: $dest appeared while the copy was made; leaving it as it is"
	fi
	mv -T "$tmp" "$dest"
	tmp=
	say "$zone seeded at $dest content_sha256=$content tree_sha256=$want"
}

read -ra zones <<<"${RIFTAL_LEVEL_ZONES:-}"
if [ -n "${RIFTAL_SEED_CHOWN:-}" ] && [[ ! "$RIFTAL_SEED_CHOWN" =~ ^[1-9][0-9]*:[0-9]+$ ]]; then
	refuse "RIFTAL_SEED_CHOWN must be <uid>:<gid> with a uid that is not root"
fi
if [ "$(id -u)" -eq 0 ] && [ -z "${RIFTAL_SEED_CHOWN:-}" ] && [ "${#zones[@]}" -gt 0 ]; then
	refuse "running as root; the seeded folder would not be owned by the server's user"
fi
clear_leftovers
if [ "${#zones[@]}" -eq 0 ]; then
	say "no zones listed; nothing seeded"
fi
for zone in "${zones[@]}"; do
	seed_zone "$zone"
done

exec "$@"
