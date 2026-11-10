#!/usr/bin/env bash
# Self-test for release-image.sh (riftal-infra#1251, #1422): the tag follows
# spec 016's naming, <date>-core<7>-game<7>-infra<7>, and changes with the
# riftal-game commit and the riftal-infra commit. Malformed tag input, each phar
# when empty, a GAME_COMMIT that is not a full lowercase sha, a GRANTS_SQL that
# is not a non-empty regular file, an INFRA_DIR that is not a git checkout or
# has a tracked change, and an existing tag are refused. The image records
# GAME_COMMIT, the riftal-infra commit and the sha256 of GRANTS_SQL in its
# labels and holds no grants.sql. The image it builds is on
# ubuntu:24.04 and the pinned core revision, holds the phars named in
# REQUIRED_PHARS intact in /opt/riftal/plugins, owned by root, mode 0444 and in
# a root-owned 0755 directory pocketmine cannot write, holds none in /plugins,
# has pocketmine as its configured user and is never tagged latest. Builds on
# the local daemon under a riftal_smoke_ name and removes it. Needs the core
# image pinned in images/core-image.sha.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/release-image.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=50
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

sha="$(tr -d '[:space:]' < "$DIR/../images/core-image.sha")"
image="riftal_smoke_release/pocketmine-mp"
GAME_COMMIT=0123456789abcdef0123456789abcdef01234567
work="$(mktemp -d)"
infra="$work/infra"
git init -q "$infra"
printf 'one\n' > "$infra/tracked"
git -C "$infra" add tracked
git -C "$infra" -c user.name=selftest -c user.email=selftest@example.invalid -c commit.gpgsign=false commit -q -m fixture
infra_sha="$(git -C "$infra" rev-parse HEAD)"
tag="2026-10-21-core${sha:0:7}-game${GAME_COMMIT:0:7}-infra${infra_sha:0:7}"
cleanup() {
  docker image rm "$image:$tag" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

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
export GAME_COMMIT INFRA_DIR="$infra"
export GRANTS_SQL="$work/grants.sql"
printf 'REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines;\n' > "$GRANTS_SQL"
for name in "${REQUIRED_PHARS[@]}"; do
  printf 'phar %s\n' "$name" > "$phars/$name"
done

for name in "${REQUIRED_PHARS[@]}"; do
  : > "$phars/$name"
  if out="$(RELEASE_IMAGE=$image RELEASE_DATE=2026-10-21 main "$phars" 2>&1)"; then
    fail "an empty $name was accepted"
  elif grep -qF "$name is missing or empty" <<<"$out"; then
    pass "an empty $name is refused by name"
  else
    fail "an empty $name was refused without naming it: $out"
  fi
  printf 'phar %s\n' "$name" > "$phars/$name"
done

for bad in "" 0123456789abcdef 0123456789ABCDEF0123456789ABCDEF01234567 "${GAME_COMMIT}0"; do
  if out="$(GAME_COMMIT=$bad RELEASE_IMAGE=$image RELEASE_DATE=2026-10-21 main "$phars" 2>&1)"; then
    fail "GAME_COMMIT '$bad' was accepted"
  elif grep -qF "GAME_COMMIT \"$bad\" is not a full 40-character" <<<"$out"; then
    pass "GAME_COMMIT '$bad' is refused by value"
  else
    fail "GAME_COMMIT '$bad' was refused without naming it: $out"
  fi
done
: > "$work/empty.sql"
for bad in "" "$work/gone.sql" "$work/empty.sql" "$work"; do
  if out="$(GRANTS_SQL=$bad RELEASE_IMAGE=$image RELEASE_DATE=2026-10-21 main "$phars" 2>&1)"; then
    fail "GRANTS_SQL '$bad' was accepted"
  elif grep -qF "GRANTS_SQL \"$bad\" is not a non-empty regular file" <<<"$out"; then
    pass "GRANTS_SQL '$bad' is refused by value"
  else
    fail "GRANTS_SQL '$bad' was refused without naming it: $out"
  fi
done

# $1 the INFRA_DIR to build from, $2 the message the refusal must carry, $3 the case.
refuses_infra() {
  local out
  if out="$(INFRA_DIR=$1 RELEASE_IMAGE=$image RELEASE_DATE=2026-10-21 main "$phars" 2>&1)"; then
    fail "$3 was accepted"
  elif grep -qF "$2" <<<"$out" && ! docker image inspect "$image:$tag" >/dev/null 2>&1; then
    pass "$3 is refused before a build"
  else
    fail "$3 was refused without saying why: $out"
  fi
}
mkdir "$work/plain"
refuses_infra "$work/plain" "is not a git checkout with a commit" "an INFRA_DIR that is not a git checkout"
refuses_infra "$work/gone" "is not a git checkout with a commit" "an INFRA_DIR that does not exist"
git init -q "$work/unborn"
refuses_infra "$work/unborn" "is not a git checkout with a commit" "an INFRA_DIR with no commit"
printf 'two\n' > "$infra/tracked"
refuses_infra "$infra" "has tracked changes since $infra_sha" "an INFRA_DIR with a modified tracked file"
git -C "$infra" checkout -q -- tracked
printf 'new\n' > "$infra/added"
git -C "$infra" add added
refuses_infra "$infra" "has tracked changes since $infra_sha" "an INFRA_DIR with a staged new file"
git -C "$infra" reset -q
if [ "$(infra_commit "$infra" 2>&1)" = "$infra_sha" ]; then
  pass "an INFRA_DIR with only an untracked file is named by its HEAD"
else
  fail "an INFRA_DIR with only an untracked file was not named by $infra_sha"
fi

if out="$(RELEASE_IMAGE=$image RELEASE_DATE=2026-10-21 main "$phars" 2>&1)"; then
  pass "the release image builds"
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
  for name in "${REQUIRED_PHARS[@]}"; do
    want="$(sha256sum "$phars/$name" | cut -d' ' -f1)"
    got="$(docker run --rm -m 1g --cpus 1 --entrypoint sha256sum "$image:$tag" "/opt/riftal/plugins/$name" | cut -d' ' -f1 || true)"
    [ "$got" = "$want" ] || mismatch=$((mismatch + 1))
  done
  if [ "$mismatch" -eq 0 ]; then
    pass "every phar in /opt/riftal/plugins matches its source sha256"
  else
    fail "$mismatch phar(s) in /opt/riftal/plugins are not the ones given"
  fi
  want_list="$(printf '/opt/riftal/plugins/%s\n' "${REQUIRED_PHARS[@]}" | sort)"
  got_list="$(docker run --rm -m 1g --cpus 1 --entrypoint sh "$image:$tag" -c 'find /opt/riftal/plugins -mindepth 1 | sort')"
  if [ "$got_list" = "$want_list" ]; then
    pass "/opt/riftal/plugins holds exactly the required phars"
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
    pass "every phar in /opt/riftal/plugins is owned by root and mode 444"
  else
    fail "phar(s) not owned by root or not mode 444: $unowned"
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
    pass "pocketmine can write none of /opt/riftal, /opt/riftal/plugins or a phar in it"
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
fi

if out="$(RELEASE_IMAGE=$image RELEASE_DATE=2026-10-21 main "$phars" 2>&1)"; then
  fail "a second build of the same tag was accepted"
elif grep -qF "is immutable" <<<"$out"; then
  pass "a tag that exists is refused"
else
  fail "a repeated tag was refused without saying why: $out"
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
