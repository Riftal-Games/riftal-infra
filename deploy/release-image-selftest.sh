#!/usr/bin/env bash
# Self-test for release-image.sh (riftal-infra#1251): the tag follows spec 016's
# naming, every way of not producing a release is refused, and the image it
# builds is on ubuntu:24.04 and the pinned core revision, holds exactly the six
# production phars intact in /opt/riftal/plugins, owned by pocketmine and
# read-only, holds none in /plugins, runs unprivileged and is never tagged
# latest. Builds on the local daemon under a riftal_smoke_ name and removes it.
# Needs the core image pinned in images/core-image.sha.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/release-image.sh"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=23
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

sha="$(tr -d '[:space:]' < "$DIR/../images/core-image.sha")"
image="riftal_smoke_release/pocketmine-mp"
tag="core-2026-10-21-${sha:0:7}"
work="$(mktemp -d)"
cleanup() {
  docker image rm "$image:$tag" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

if [ "$(release_tag core 2026-10-21 "$sha")" = "$tag" ]; then
  pass "the tag is $tag"
else
  fail "the tag was not $tag"
fi
if [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ && "$tag" != latest ]]; then
  pass "the tag is one the deploy scripts accept"
else
  fail "$tag is not an accepted image tag"
fi
for bad in "core 2026-10-2 $sha" "core 2026-10-21 ${sha:0:7}" "core 2026-10-21 latest" "Core 2026-10-21 $sha"; do
  # shellcheck disable=SC2086
  if release_tag $bad >/dev/null 2>&1; then
    fail "release_tag accepted: $bad"
  else
    pass "release_tag refuses: $bad"
  fi
done

phars="$work/phars"
mkdir "$phars"
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
    pass "the image runs as pocketmine"
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
  unowned="$(docker run --rm -m 1g --cpus 1 --entrypoint sh "$image:$tag" -c 'find /opt/riftal/plugins -type f \( ! -user pocketmine -o ! -perm 444 \)')"
  if [ -z "$unowned" ]; then
    pass "every phar in /opt/riftal/plugins is owned by pocketmine and read-only"
  else
    fail "phar(s) not owned by pocketmine or not mode 444: $unowned"
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
