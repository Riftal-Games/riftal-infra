#!/usr/bin/env bash
# Self-test for release-image.sh (riftal-infra#1251, #1422): the tag follows
# spec 016's naming, <date>-core<7>-game<7>-infra<7>, and changes with the
# riftal-game commit and the riftal-infra commit. Malformed tag input, each
# phar when empty, a GAME_COMMIT that is not a full lowercase sha, a GRANTS_SQL
# that is not a non-empty regular file, a checkout that is not the top of a git
# work tree of its own, whose status git cannot report or that has a tracked
# change, and an existing tag are refused. Every case runs a copy of the
# release files committed in a temporary repository, started from another
# repository's directory, so the commit it names is the one read from beside
# the script. The image records GAME_COMMIT, the riftal-infra commit and the
# sha256 of GRANTS_SQL in its labels and holds no grants.sql. The image it
# builds is on ubuntu:24.04 and the pinned core revision, holds the phars named
# in REQUIRED_PHARS intact in /opt/riftal/plugins, owned by root, mode 0444 and
# in a root-owned 0755 directory pocketmine cannot write, holds none in
# /plugins, has pocketmine as its configured user and is never tagged latest.
# Each file of SHIPPED_PLUGINS is held in /opt/riftal/plugins likewise.
# The levels are fixtures: two zones in volumes of the self-test's own
# riftal_smoke_ prefix, locked against the pinned core image, never the dev
# stack's build volumes or the committed locks. A volume that is missing, a
# manifest whose content_sha256 is not the lock's, a tree that is not its
# manifest's and a lock built on another core image are each refused naming the
# zone, and so is a locks directory with no lock, all before a build. In the
# image, the world index and the three boot scripts equal the checkout's,
# /etc/riftal/levels holds the locked zones and no other, each hashing to its
# manifest, the digest list checks and the labels record them, and pocketmine
# can write nothing under /etc/riftal or /opt/riftal/boot.
# The ops image built beside it (ADR 045 item 1) is inspected only by running
# explicit harmless commands in it, never its own command, which is the backup
# loop. Its ops.sha256 lists the checkout's host files, the zone locks, the
# MIGRATIONS_DIR files and GRANTS_SQL byte for byte and verifies in it, nothing
# else is under /opt/riftal, root owns it all with files 0444, scripts 0555 and
# directories 0755, its labels equal the release image's and record the
# migrations and ops.sha256, the release image's org.riftal.backup-image is its
# id, and its command is backup-loop.sh. Every top-level .sh of deploy/,
# migrations/ and images/ is on exactly one of the two lists, a fixture script on
# neither or on both fails the build naming it, as does a MIGRATIONS_DIR with no
# .sql file, and an existing ops image tag is refused.
# Builds on the local daemon under riftal_smoke_ names and removes them. Needs
# the core image pinned in images/core-image.sha.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/release-fixture.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=85
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

boot_scripts=(deliver-world-index.sh seed-levels.sh level-args.sh)

git_fixture() {
  git -c user.name=selftest -c user.email=selftest@example.invalid -c commit.gpgsign=false "$@"
}
# $1 the root to lay the release files out under, at their repository paths.
copy_release_files() {
  mkdir -p "$1/deploy" "$1/designer" "$1/images/release" "$1/images/plugins/instance-only"
  cp "$DIR/release-image.sh" "$1/deploy/"
  cp "$DIR/../designer/world_index.json" "$1/designer/"
  for name in "${boot_scripts[@]}"; do cp "$DIR/../images/plugins/$name" "$1/images/plugins/"; done
  cp "$DIR/../images/core-image.sh" "$DIR/../images/core-image.sha" "$1/images/"
  cp "$DIR/../images/release/Dockerfile" "$DIR/../images/release/Dockerfile.backup" "$DIR/../images/release/start-release.sh" "$1/images/release/"
  mkdir -p "$1/migrations" "$1/images/backup"
  cp "$DIR"/*.sh "$DIR"/*.md "$DIR/write-latency-probe.php" "$1/deploy/"
  cp "$DIR"/../migrations/*.sh "$DIR/../migrations/README.md" "$1/migrations/"
  cp "$DIR"/../images/*.sh "$DIR/../images/README.md" "$1/images/"
  cp "$DIR/../images/backup/Dockerfile" "$1/images/backup/"
  cp "$DIR/../images/plugins/RiftalAccounts.config.yml" "$DIR/../images/plugins/RiftalDownstreamLimit.php" "$1/images/plugins/"
  cp "$DIR/../images/plugins/instance-only/RiftalMines.config.yml.template"     "$DIR/../images/plugins/instance-only/RiftalRanks.config.yml"     "$DIR/../images/plugins/instance-only/RiftalEconomy.config.yml"     "$1/images/plugins/instance-only/"
}
# $1 a new repository root holding one commit of the release files.
commit_checkout() {
  copy_release_files "$1"
  git init -q "$1"
  git_fixture -C "$1" add -A
  git_fixture -C "$1" commit -q -m fixture
}

sha="$(tr -d '[:space:]' < "$DIR/../images/core-image.sha")"
image="riftal_smoke_release/pocketmine-mp"
bimage="riftal_smoke_release/backup"
GAME_COMMIT=0123456789abcdef0123456789abcdef01234567
work="$(mktemp -d)"
infra="$work/infra"
commit_checkout "$infra"
infra_sha="$(git -C "$infra" rev-parse HEAD)"
tag="2026-10-21-core${sha:0:7}-game${GAME_COMMIT:0:7}-infra${infra_sha:0:7}"
# A different repository with a commit of its own, as the working directory of
# every run, so a commit read from the working directory names the wrong one.
elsewhere="$work/elsewhere"
commit_checkout "$elsewhere"
printf 'marker\n' > "$elsewhere/marker"
git_fixture -C "$elsewhere" add marker
git_fixture -C "$elsewhere" commit -q -m marker
cd "$elsewhere"
. "$infra/deploy/release-image.sh"
level_prefix="riftal_smoke_rel_$$_level_"
level_vols=()
cleanup() {
  docker image rm "$image:$tag" "$bimage:$tag" "$bimage-base:$tag" >/dev/null 2>&1 || true
  docker volume rm "${level_vols[@]}" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

core_image
core_id="$(docker image inspect --format '{{.Id}}' "$CORE_IMAGE")"
content_a="$(printf 'a%.0s' {1..64})"
content_b="$(printf 'b%.0s' {1..64})"
locks="$work/locks"
mkdir "$locks"
# $1 zone, $2 the content_sha256 its manifest and lock record. Creates its
# build volume under the self-test's own prefix and locks it.
fixture_level() {
  level_vols+=("$level_prefix$1")
  docker volume create "$level_prefix$1" >/dev/null
  fixture_tree "$level_prefix$1" "$1"
  fixture_manifest "$level_prefix$1" "$2"
  fixture_lock "$locks" "$1" "$2" "$core_id"
}
fixture_level smoke_a "$content_a"
fixture_level smoke_b "$content_b"
export LEVEL_LOCKS_DIR="$locks" LEVEL_VOLUME_PREFIX="$level_prefix"

if [ "$(release_tag 2026-10-21 "$sha" "$GAME_COMMIT" "$infra_sha")" = "$tag" ]; then
  pass "the tag is $tag"
else
  fail "the tag was not $tag"
fi
if [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ && "$tag" != latest ]]; then
  pass "the tag is one the deploy scripts accept"
else
  fail "$tag is not an accepted image tag"
fi
other_game=fedcba9876543210fedcba9876543210fedcba98
other_infra=89abcdef0123456789abcdef0123456789abcdef
if [ "$(release_tag 2026-10-21 "$sha" "$other_game" "$infra_sha")" != "$tag" ]; then
  pass "a different riftal-game commit gives a different tag"
else
  fail "a different riftal-game commit gave the same tag"
fi
if [ "$(release_tag 2026-10-21 "$sha" "$GAME_COMMIT" "$other_infra")" != "$tag" ]; then
  pass "a different riftal-infra commit gives a different tag"
else
  fail "a different riftal-infra commit gave the same tag"
fi
other_core=76543210fedcba9876543210fedcba9876543210
if [ "$(release_tag 2026-10-21 "$other_core" "$GAME_COMMIT" "$infra_sha")" != "$tag" ]; then
  pass "a different core pin gives a different tag"
else
  fail "a different core pin gave the same tag"
fi
for bad in "2026-10-2 $sha $GAME_COMMIT $infra_sha" "2026-10-21 ${sha:0:7} $GAME_COMMIT $infra_sha" \
  "2026-10-21 $sha ${GAME_COMMIT:0:7} $infra_sha" "2026-10-21 $sha $GAME_COMMIT latest" \
  "2026-10-21 $sha ${GAME_COMMIT^^} $infra_sha"; do
  # shellcheck disable=SC2086
  if release_tag $bad >/dev/null 2>&1; then
    fail "release_tag accepted: $bad"
  else
    pass "release_tag refuses: $bad"
  fi
done

phars="$work/phars"
mkdir "$phars"
export GAME_COMMIT
export GRANTS_SQL="$work/grants.sql"
migrations="$work/migrations"
mkdir "$migrations" "$work/nosql"
printf 'CREATE TABLE smoke_a (id INT);\n' > "$migrations/0001_a.sql"
printf 'CREATE TABLE smoke_b (id INT);\n' > "$migrations/0002_b.sql"
printf 'not a migration\n' > "$migrations/notes.txt"
cp "$migrations/notes.txt" "$work/nosql/"
export MIGRATIONS_DIR="$migrations"
# $1 the root of a checkout of the release files, whose script is run as a
# release runs it.
release_from() {
  RELEASE_IMAGE=$image BACKUP_IMAGE=$bimage RELEASE_DATE=2026-10-21 bash "$1/deploy/release-image.sh" "$phars"
}
printf 'REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines;\n' > "$GRANTS_SQL"
for name in "${REQUIRED_PHARS[@]}"; do
  printf 'phar %s\n' "$name" > "$phars/$name"
done

for name in "${REQUIRED_PHARS[@]}"; do
  : > "$phars/$name"
  if out="$(release_from "$infra" 2>&1)"; then
    fail "an empty $name was accepted"
  elif grep -qF "$name is missing or empty" <<<"$out"; then
    pass "an empty $name is refused by name"
  else
    fail "an empty $name was refused without naming it: $out"
  fi
  printf 'phar %s\n' "$name" > "$phars/$name"
done

for bad in "" 0123456789abcdef 0123456789ABCDEF0123456789ABCDEF01234567 "${GAME_COMMIT}0"; do
  if out="$(GAME_COMMIT=$bad release_from "$infra" 2>&1)"; then
    fail "GAME_COMMIT '$bad' was accepted"
  elif grep -qF "GAME_COMMIT \"$bad\" is not a full 40-character" <<<"$out"; then
    pass "GAME_COMMIT '$bad' is refused by value"
  else
    fail "GAME_COMMIT '$bad' was refused without naming it: $out"
  fi
done
: > "$work/empty.sql"
for bad in "" "$work/gone.sql" "$work/empty.sql" "$work"; do
  if out="$(GRANTS_SQL=$bad release_from "$infra" 2>&1)"; then
    fail "GRANTS_SQL '$bad' was accepted"
  elif grep -qF "GRANTS_SQL \"$bad\" is not a non-empty regular file" <<<"$out"; then
    pass "GRANTS_SQL '$bad' is refused by value"
  else
    fail "GRANTS_SQL '$bad' was refused without naming it: $out"
  fi
done
for bad in "" "$work/gone" "$work/nosql" "$GRANTS_SQL"; do
  if out="$(MIGRATIONS_DIR=$bad release_from "$infra" 2>&1)"; then
    fail "MIGRATIONS_DIR '$bad' was accepted"
  elif grep -qF "MIGRATIONS_DIR \"$bad\" is not a directory holding a .sql file" <<<"$out"; then
    pass "MIGRATIONS_DIR '$bad' is refused by value"
  else
    fail "MIGRATIONS_DIR '$bad' was refused without naming it: $out"
  fi
done

# $1 the checkout to run, $2 the message the refusal must carry, $3 the case.
refuses_infra() {
  local out
  if out="$(release_from "$1" 2>&1)"; then
    fail "$3 was accepted"
  elif grep -qF "$2" <<<"$out" && [ -z "$(docker image ls -q "$image")" ]; then
    pass "$3 is refused before a build"
  else
    fail "$3 was refused without saying why: $out"
  fi
}
copy_release_files "$work/plain"
refuses_infra "$work/plain" "is not a git checkout with a commit" "a checkout with no .git"
copy_release_files "$work/unborn"
git init -q "$work/unborn"
refuses_infra "$work/unborn" "is not a git checkout with a commit" "a checkout with no commit"
copy_release_files "$infra/.git"
refuses_infra "$infra/.git" "is not the top of its own git work tree" "release files inside a .git directory"
rm -rf "$infra/.git/deploy" "$infra/.git/images"
copy_release_files "$infra/sub"
refuses_infra "$infra/sub" "is not the top of its own git work tree" "release files in an untracked subdirectory of a repository"
rm -rf "$infra/sub"
commit_checkout "$work/badindex"
printf 'not an index\n' > "$work/badindex/.git/index"
refuses_infra "$work/badindex" "git status failed in" "a checkout whose status git cannot report"
printf '\n' >> "$infra/images/release/Dockerfile"
refuses_infra "$infra" "has tracked changes since $infra_sha" "a checkout with a modified tracked file"
git -C "$infra" checkout -q -- images/release/Dockerfile
printf 'new\n' > "$infra/added"
git -C "$infra" add added
refuses_infra "$infra" "has tracked changes since $infra_sha" "a checkout with a staged new file"
git -C "$infra" reset -q

if out="$(classify_scripts "$infra")"; then
  pass "every top-level .sh of deploy, migrations and images is on exactly one list"
else
  fail "the lists do not sort every script: $out"
fi
commit_checkout "$work/unclassified"
printf '#!/bin/sh\n' > "$work/unclassified/deploy/new-tool.sh"
git_fixture -C "$work/unclassified" add -A
git_fixture -C "$work/unclassified" commit -q -m unclassified
refuses_infra "$work/unclassified" "deploy/new-tool.sh is on neither" "a script on neither list"
if out="$(NOT_CARRIED_SCRIPTS+=(deploy/backup.sh); classify_scripts "$infra")"; then
  fail "a script on both lists was accepted"
elif grep -qF "deploy/backup.sh is on both" <<<"$out"; then
  pass "a script on both lists is refused by name"
else
  fail "a script on both lists was refused without naming it: $out"
fi

# $1 a locks directory, $2 the zone the refusal must name, $3 the message it
# must carry, $4 the case. A refused build leaves no image.
refuses_levels() {
  local out
  if out="$(LEVEL_LOCKS_DIR="$1" release_from "$infra" 2>&1)"; then
    fail "$4 was accepted"
  elif grep -qF "zone $2: " <<<"$out" && grep -qF -- "$3" <<<"$out" && [ -z "$(docker image ls -q "$image")" ]; then
    pass "$4 is refused naming zone $2, before a build"
  else
    fail "$4 was refused without naming zone $2 and '$3': $out"
  fi
}
# $1 a case name. Prints a copy of the fixture locks to change.
locks_for() {
  cp -r "$locks" "$work/locks-$1"
  printf '%s\n' "$work/locks-$1"
}
case_dir="$(locks_for missing)"
fixture_lock "$case_dir" smoke_c "$content_a" "$core_id"
refuses_levels "$case_dir" smoke_c "build volume ${level_prefix}smoke_c is not on this daemon" "a lock with no build volume"
if docker volume inspect "${level_prefix}smoke_c" >/dev/null 2>&1; then
  docker volume rm "${level_prefix}smoke_c" >/dev/null 2>&1 || true
  fail "the refused build created volume ${level_prefix}smoke_c"
else
  pass "the refused build created no volume"
fi
case_dir="$(locks_for content)"
fixture_lock "$case_dir" smoke_a "$(printf 'c%.0s' {1..64})" "$core_id"
refuses_levels "$case_dir" smoke_a "holds content_sha256 $content_a and the lock holds" "a manifest whose content_sha256 is not the lock's"
level_vols+=("${level_prefix}smoke_t")
docker volume create "${level_prefix}smoke_t" >/dev/null
fixture_tree "${level_prefix}smoke_t" smoke_t
fixture_manifest "${level_prefix}smoke_t" "$content_a"
docker run --rm -m 1g --cpus 1 --network none --user root -v "${level_prefix}smoke_t:/level" \
  --entrypoint bash "$CORE_IMAGE" -c 'printf "added after the manifest\n" >/level/db/added'
case_dir="$(locks_for tree)"
fixture_lock "$case_dir" smoke_t "$content_a" "$core_id"
refuses_levels "$case_dir" smoke_t "does not hash to the" "a tree that is not its manifest's"
case_dir="$(locks_for core)"
fixture_lock "$case_dir" smoke_a "$content_a" "sha256:$(printf '0%.0s' {1..64})"
refuses_levels "$case_dir" smoke_a "its lock was built on core image sha256:0000" "a lock built on another core image"
mkdir "$work/locks-none"
if out="$(LEVEL_LOCKS_DIR="$work/locks-none" release_from "$infra" 2>&1)"; then
  fail "a locks directory with no lock was accepted"
elif grep -qF "holds no <zone>.lock.json" <<<"$out" && [ -z "$(docker image ls -q "$image")" ]; then
  pass "a locks directory with no lock is refused before a build"
else
  fail "a locks directory with no lock was refused without saying why: $out"
fi

if out="$(release_from "$infra" 2>&1)"; then
  pass "the release image builds from a checkout with an untracked file"
else
  fail "the build failed: $out"
fi

if ! docker image inspect "$image:$tag" >/dev/null 2>&1; then
  fail "$image:$tag is not on the daemon"
else
  pass "$image:$tag is on the daemon"
  if docker image inspect "$image:latest" >/dev/null 2>&1; then
    fail "a latest tag exists"
  else
    pass "no latest tag exists"
  fi
  mismatch=0
  for name in "${REQUIRED_PHARS[@]}" "${SHIPPED_PLUGINS[@]}"; do
    src="$phars/$name"
    [ -f "$src" ] || src="$DIR/../images/plugins/$name"
    want="$(sha256sum "$src" | cut -d' ' -f1)"
    got="$(docker run --rm -m 1g --cpus 1 --entrypoint sha256sum "$image:$tag" "/opt/riftal/plugins/$name" | cut -d' ' -f1 || true)"
    [ "$got" = "$want" ] || mismatch=$((mismatch + 1))
  done
  if [ "$mismatch" -eq 0 ]; then
    pass "every phar and script plugin in /opt/riftal/plugins matches its source sha256"
  else
    fail "$mismatch file(s) in /opt/riftal/plugins are not the ones given"
  fi
  want_list="$(printf '/opt/riftal/plugins/%s\n' "${REQUIRED_PHARS[@]}" "${SHIPPED_PLUGINS[@]}" RiftalDownstreamLimit.php | sort -u)"
  got_list="$(docker run --rm -m 1g --cpus 1 --entrypoint sh "$image:$tag" -c 'find /opt/riftal/plugins -mindepth 1 | sort')"
  if [ "$got_list" = "$want_list" ]; then
    pass "/opt/riftal/plugins holds exactly the required phars and script plugins"
  else
    fail "/opt/riftal/plugins holds: $got_list"
  fi
  os="$(docker run --rm -m 1g --cpus 1 --entrypoint sh "$image:$tag" -c '. /etc/os-release && echo "$ID $VERSION_ID"')"
  if [ "$os" = "ubuntu 24.04" ]; then
    pass "the image is ubuntu 24.04"
  else
    fail "the image is $os, not ubuntu 24.04"
  fi
  user="$(docker image inspect --format '{{.Config.User}}' "$image:$tag")"
  if [ "$user" = pocketmine ]; then
    pass "the image's configured user is pocketmine"
  else
    fail "the image runs as '$user'"
  fi
  # The revision label is inherited from the base, so it names the core build
  # the layers came from; the org.riftal.core-image label only records the
  # argument the script passed.
  revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image:$tag")"
  if [ "$revision" = "$sha" ]; then
    pass "the image is built on the pinned core revision"
  else
    fail "the image is built on core revision '$revision', not the pinned $sha"
  fi
  label_game="$(docker image inspect --format '{{index .Config.Labels "org.riftal.game-commit"}}' "$image:$tag")"
  if [ "$label_game" = "$GAME_COMMIT" ]; then
    pass "the image names the riftal-game commit in org.riftal.game-commit"
  else
    fail "org.riftal.game-commit is '$label_game', not $GAME_COMMIT"
  fi
  label_infra="$(docker image inspect --format '{{index .Config.Labels "org.riftal.infra-commit"}}' "$image:$tag")"
  if [ "$label_infra" = "$infra_sha" ]; then
    pass "the image names the riftal-infra commit in org.riftal.infra-commit"
  else
    fail "org.riftal.infra-commit is '$label_infra', not $infra_sha"
  fi
  label_grants="$(docker image inspect --format '{{index .Config.Labels "org.riftal.grants-sha256"}}' "$image:$tag")"
  if [ "$label_grants" = "$(sha256sum "$GRANTS_SQL" | cut -d' ' -f1)" ]; then
    pass "the image records the sha256 of grants.sql in org.riftal.grants-sha256"
  else
    fail "org.riftal.grants-sha256 is '$label_grants', not the sha256 of the given grants.sql"
  fi
  grants_files="$(docker run --rm -m 1g --cpus 1 --entrypoint sh "$image:$tag" -c 'find / -xdev -name grants.sql 2>/dev/null; true')"
  if [ -z "$grants_files" ]; then
    pass "the image holds no grants.sql"
  else
    fail "grants.sql in the image: $grants_files"
  fi
  unowned="$(docker run --rm -m 1g --cpus 1 --entrypoint sh "$image:$tag" -c 'find /opt/riftal/plugins -type f \( ! -user root -o ! -perm 444 \)')"
  if [ -z "$unowned" ]; then
    pass "every file in /opt/riftal/plugins is owned by root and mode 444"
  else
    fail "file(s) not owned by root or not mode 444: $unowned"
  fi
  dirs="$(docker run --rm -m 1g --cpus 1 --entrypoint stat "$image:$tag" -c '%n %U %a' /opt/riftal /opt/riftal/plugins)"
  want_dirs="$(printf '%s\n' '/opt/riftal root 755' '/opt/riftal/plugins root 755')"
  if [ "$dirs" = "$want_dirs" ]; then
    pass "/opt/riftal and /opt/riftal/plugins are owned by root and mode 755"
  else
    fail "the directories are: $dirs"
  fi
  writable="$(docker run --rm -m 1g --cpus 1 --user pocketmine --entrypoint sh "$image:$tag" -c 'for p in /opt/riftal /opt/riftal/plugins /opt/riftal/plugins/*; do [ -w "$p" ] && echo "$p"; done; true')"
  if [ -z "$writable" ]; then
    pass "pocketmine can write none of /opt/riftal, /opt/riftal/plugins or a file in it"
  else
    fail "pocketmine can write: $writable"
  fi
  # A phar under /plugins would be hidden by a mount or outlived by a reused
  # volume, so the tag would not decide which build runs.
  volume_phars="$(docker run --rm -m 1g --cpus 1 --entrypoint sh "$image:$tag" -c 'find /plugins -name "*.phar"')"
  if [ -z "$volume_phars" ]; then
    pass "/plugins in the image holds no phar"
  else
    fail "phar(s) under /plugins: $volume_phars"
  fi

  # $@ a command to run in the image as its configured user.
  in_image() { docker run --rm -m 1g --cpus 1 --network none --entrypoint "$1" "$image:$tag" "${@:2}"; }
  want_index="$(sha256sum "$DIR/../designer/world_index.json" | cut -d' ' -f1)"
  got_index="$(in_image sha256sum /etc/riftal/world_index.json | cut -d' ' -f1)"
  if [ "$got_index" = "$want_index" ]; then
    pass "/etc/riftal/world_index.json is designer/world_index.json byte for byte"
  else
    fail "the image's world index is $got_index, not $want_index"
  fi
  mismatch=0
  for name in "${boot_scripts[@]}"; do
    want="$(sha256sum "$DIR/../images/plugins/$name" | cut -d' ' -f1)"
    got="$(in_image sha256sum "/opt/riftal/boot/$name" | cut -d' ' -f1 || true)"
    [ "$got" = "$want" ] || mismatch=$((mismatch + 1))
  done
  if [ "$mismatch" -eq 0 ]; then
    pass "the three boot scripts in /opt/riftal/boot are the files in images/plugins byte for byte"
  else
    fail "$mismatch boot script(s) differ from images/plugins"
  fi

  want_zones="$(ls "$locks" | sed 's/\.lock\.json$//')"
  got_zones="$(in_image ls /etc/riftal/levels)"
  if [ "$got_zones" = "$want_zones" ]; then
    pass "/etc/riftal/levels holds exactly the locked zones"
  else
    fail "/etc/riftal/levels holds '$got_zones', the locks name '$want_zones'"
  fi
  want_levels=""
  for zone in $want_zones; do
    want_content="$content_a"
    [ "$zone" = smoke_a ] || want_content="$content_b"
    in_image cat "/etc/riftal/levels/$zone/level-manifest.json" >"$work/manifest-$zone"
    got_tree="$(in_image bash -c "cd /etc/riftal/levels/$zone && find . -type f ! -path ./level-manifest.json -printf '%P\\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum -- | sha256sum | cut -d' ' -f1")"
    if [ "$(manifest_digest "$work/manifest-$zone" tree_sha256)" = "$got_tree" ] \
      && [ "$(manifest_digest "$work/manifest-$zone" content_sha256)" = "$want_content" ]; then
      pass "zone $zone in the image hashes to its manifest and carries its lock's content_sha256"
    else
      fail "zone $zone in the image hashes to $got_tree, its manifest: $(cat "$work/manifest-$zone")"
    fi
    want_levels+="${want_levels:+,}$zone=$want_content:$got_tree"
  done
  label_index="$(docker image inspect --format '{{index .Config.Labels "org.riftal.world-index-sha256"}}' "$image:$tag")"
  label_levels="$(docker image inspect --format '{{index .Config.Labels "org.riftal.levels"}}' "$image:$tag")"
  if [ "$label_index" = "$want_index" ]; then
    pass "org.riftal.world-index-sha256 is the index's sha256"
  else
    fail "org.riftal.world-index-sha256 is '$label_index', not $want_index"
  fi
  if [ "$label_levels" = "$want_levels" ]; then
    pass "org.riftal.levels records each zone's content_sha256 and tree_sha256"
  else
    fail "org.riftal.levels is '$label_levels', not '$want_levels'"
  fi

  want_list="$(printf '%s\n' "/etc/riftal/world_index.json" "/etc/riftal/levels/smoke_a/level-manifest.json" "/etc/riftal/levels/smoke_b/level-manifest.json")"
  got_list="$(in_image cut -d' ' -f3- /opt/riftal/boot/etc-riftal.sha256)"
  if in_image sha256sum -c --quiet /opt/riftal/boot/etc-riftal.sha256 >/dev/null 2>&1 && [ "$got_list" = "$want_list" ]; then
    pass "etc-riftal.sha256 lists the index and each zone's manifest, and /etc/riftal checks against it"
  else
    fail "etc-riftal.sha256 lists: $got_list"
  fi

  odd_files="$(in_image find /etc/riftal /opt/riftal/boot -type f \( ! -user root -o \( ! -name '*.sh' ! -perm 444 \) -o \( -name '*.sh' ! -perm 555 \) \))"
  odd_dirs="$(in_image find /etc/riftal /opt/riftal/boot -type d \( ! -user root -o ! -perm 755 \))"
  if [ -z "$odd_files$odd_dirs" ]; then
    pass "everything under /etc/riftal and /opt/riftal/boot is root-owned, files 444, scripts 555, directories 755"
  else
    fail "not root-owned or not the expected mode: $odd_files $odd_dirs"
  fi
  writable="$(in_image find /etc/riftal /opt/riftal/boot -writable)"
  if [ -z "$writable" ]; then
    pass "pocketmine can write nothing under /etc/riftal or /opt/riftal/boot"
  else
    fail "pocketmine can write: $writable"
  fi
fi

if ! docker image inspect "$bimage:$tag" >/dev/null 2>&1; then
  fail "$bimage:$tag is not on the daemon"
else
  pass "$bimage:$tag is on the daemon, under the release image's tag"
  # $1 a command to run in the ops image in place of its own command, which is
  # the backup loop.
  in_b() { docker run --rm -m 1g --cpus 1 --network none --entrypoint "$1" "$bimage:$tag" "${@:2}"; }
  label_of() { docker image inspect --format "{{index .Config.Labels \"$2\"}}" "$1"; }
  sums_of() { local f; for f in "$@"; do printf '%s  %s\n' "$(sha256sum "${f%%:*}" | cut -d' ' -f1)" "${f#*:}"; done; }
  want_src=()
  for rel in "${HOST_SCRIPTS[@]}" deploy/write-latency-probe.php migrations/README.md images/README.md; do
    want_src+=("$infra/$rel:ops/$rel")
  done
  for f in "$infra"/deploy/*.md; do want_src+=("$f:ops/deploy/${f##*/}"); done
  for f in "$locks"/*.lock.json; do want_src+=("$f:ops/designer/levels/${f##*/}"); done
  for f in "$migrations"/*.sql; do want_src+=("$f:sql/migrations/${f##*/}"); done
  want_src+=("$GRANTS_SQL:sql/grants.sql")
  want_sums="$(sums_of "${want_src[@]}" | LC_ALL=C sort -k2)"
  got_sums="$(in_b cat /opt/riftal/ops.sha256)"
  got_files="$(in_b find /opt/riftal -type f | LC_ALL=C sort)"
  want_files="$({ sed 's|^[0-9a-f]*  |/opt/riftal/|' <<<"$want_sums"; echo /opt/riftal/ops.sha256; } | LC_ALL=C sort)"
  if [ "$got_sums" = "$want_sums" ] && [ "$got_files" = "$want_files" ]; then
    pass "ops.sha256 holds the sha256 of each source file and covers every file under /opt/riftal"
  else
    fail "ops.sha256 holds: $got_sums"
  fi
  if in_b sh -c 'cd /opt/riftal && sha256sum -c --quiet ops.sha256' >/dev/null 2>&1; then
    pass "ops.sha256 verifies the tree and the SQL in the image"
  else
    fail "ops.sha256 does not verify in the image"
  fi
  odd_files="$(in_b find /opt/riftal -type f \( ! -user root -o ! -group root -o \( ! -name '*.sh' ! -perm 444 \) -o \( -name '*.sh' ! -perm 555 \) \))"
  odd_dirs="$(in_b find /opt/riftal -type d \( ! -user root -o ! -group root -o ! -perm 755 \))"
  if [ -z "$odd_files$odd_dirs" ]; then
    pass "everything under /opt/riftal in the ops image is root-owned, files 444, scripts 555, directories 755"
  else
    fail "not root-owned or not the expected mode: $odd_files $odd_dirs"
  fi
  same=1
  for name in infra-commit game-commit grants-sha256; do
    got="$(label_of "$bimage:$tag" "org.riftal.$name")"
    [ -n "$got" ] && [ "$got" = "$(label_of "$image:$tag" "org.riftal.$name")" ] || same=$name
  done
  if [ "$same" = 1 ]; then
    pass "the ops image's infra-commit, game-commit and grants-sha256 labels equal the release image's"
  else
    fail "the ops image's org.riftal.$same differs from the release image's"
  fi
  want_migrations="$(cd "$migrations" && sha256sum -- *.sql | sha256sum | cut -d' ' -f1)"
  if [ "$(label_of "$bimage:$tag" org.riftal.migrations-sha256)" = "$want_migrations" ]; then
    pass "org.riftal.migrations-sha256 is the sha256 of the sorted sha256sum list of the migrations"
  else
    fail "org.riftal.migrations-sha256 is not $want_migrations"
  fi
  if [ "$(label_of "$bimage:$tag" org.riftal.ops-sha256)" = "$(sha256sum <<<"$got_sums" | cut -d' ' -f1)" ]; then
    pass "org.riftal.ops-sha256 is the sha256 of ops.sha256"
  else
    fail "org.riftal.ops-sha256 is not the sha256 of ops.sha256"
  fi
  bid="$(docker image inspect --format '{{.Id}}' "$bimage:$tag")"
  if [ "$(label_of "$image:$tag" org.riftal.backup-image)" = "$bid" ]; then
    pass "the release image's org.riftal.backup-image is the ops image's id"
  else
    fail "org.riftal.backup-image is not $bid"
  fi
  cmd="$(docker image inspect --format '{{json .Config.Cmd}} {{json .Config.Entrypoint}}' "$bimage:$tag")"
  if [ "$cmd" = '["/opt/riftal/ops/deploy/backup-loop.sh"] null' ]; then
    pass "the ops image's command is backup-loop.sh and it sets no entrypoint"
  else
    fail "the ops image's command and entrypoint are: $cmd"
  fi
fi

if out="$(release_from "$infra" 2>&1)"; then
  fail "a second build of the same tag was accepted"
elif grep -qF "is immutable" <<<"$out"; then
  pass "a tag that exists is refused"
else
  fail "a repeated tag was refused without saying why: $out"
fi
docker image rm "$image:$tag" >/dev/null 2>&1 || true
if out="$(release_from "$infra" 2>&1)"; then
  fail "a build over an existing ops image tag was accepted"
elif grep -qF "$bimage:$tag already exists" <<<"$out" && [ -z "$(docker image ls -q "$image")" ]; then
  pass "an ops image tag that exists is refused before a build"
else
  fail "an existing ops image tag was refused without saying why: $out"
fi

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed: the release image is built, tagged and refused as specified.\n' "$PASSES"
