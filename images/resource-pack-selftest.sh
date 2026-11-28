#!/usr/bin/env bash
# Self-test for the resource pack the pit instance sends (riftal-infra#1534,
# riftal-pm spec 028). Holds images/plugins/resource_packs to what the studio
# handed over and to what PocketMine reads: the pack is the pinned bytes, its
# manifest is the studio's pack at version 1.1.0, resource_packs.yml forces the
# stack and names exactly that one file, and stage-resource-pack.sh puts both
# in a data folder on every boot, again over files it left read-only, and
# refuses a pack that differs from its recorded sha256 before writing anything.
# Needs bash, sha256sum and python3; no container engine.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/plugins/resource_packs"

# The studio's bbstudio_RP.mcpack, 1.1.0. A new studio export is a new pack:
# these three change together with the committed file and its .sha256.
PACK_SHA=bd51834be1d7e90b4bcdb1e8754a703a957883decffe23bfaf207e9c800b37a2
PACK_SIZE=525508
PACK_UUID=4a2c1634-abd2-599e-90ed-eb065aea1b96

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=14
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

py=""
for candidate in python3 python; do
  if "$candidate" -I -c 'import zipfile' >/dev/null 2>&1; then
    py="$candidate"
    break
  fi
done
if [ -z "$py" ]; then
  printf '::error::no python3 with zipfile to read the pack manifest\n'
  exit 1
fi

work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT

got="$(sha256sum "$SRC/bbstudio_RP.mcpack" | cut -d' ' -f1)"
if [ "$got" = "$PACK_SHA" ]; then
  pass "the committed pack is the pinned bytes, sha256 $PACK_SHA"
else
  fail "the committed pack has sha256 $got, not $PACK_SHA"
fi

size="$(stat -c %s "$SRC/bbstudio_RP.mcpack")"
if [ "$size" = "$PACK_SIZE" ]; then
  pass "the pack is $PACK_SIZE bytes"
else
  fail "the pack is $size bytes, not $PACK_SIZE"
fi

if [ "$(cat "$SRC/bbstudio_RP.mcpack.sha256")" = "$PACK_SHA  bbstudio_RP.mcpack" ]; then
  pass "bbstudio_RP.mcpack.sha256 names the pinned sha256 for the pack"
else
  fail "bbstudio_RP.mcpack.sha256 holds: $(cat "$SRC/bbstudio_RP.mcpack.sha256")"
fi

manifest="$("$py" -I - "$SRC/bbstudio_RP.mcpack" <<'PY'
import json, sys, zipfile
m = json.loads(zipfile.ZipFile(sys.argv[1]).read("manifest.json"))
h = m["header"]
print(h["uuid"], ".".join(map(str, h["version"])), ",".join(x["type"] for x in m["modules"]))
PY
)" || manifest="unreadable"
if [ "$manifest" = "$PACK_UUID 1.1.0 resources" ]; then
  pass "the manifest is the studio's resource pack $PACK_UUID at 1.1.0"
else
  fail "the manifest reads: $manifest"
fi

yml="$SRC/resource_packs.yml"
if [ "$(grep -c '^force_resources: true$' "$yml")" -eq 1 ] && ! grep -q '^force_resources: false' "$yml"; then
  pass "resource_packs.yml sets force_resources: true"
else
  fail "resource_packs.yml does not set force_resources: true exactly once"
fi

stack="$(awk '/^resource_stack:/{in_stack=1; next} in_stack && /^[^ #]/{in_stack=0} in_stack && /^  - /{sub(/^  - /,""); print}' "$yml")"
if [ "$stack" = "bbstudio_RP.mcpack" ]; then
  pass "resource_stack names bbstudio_RP.mcpack and nothing else"
else
  fail "resource_stack names: $stack"
fi

if [ -f "$SRC/$stack" ]; then
  pass "the file resource_stack names is beside it"
else
  fail "resource_stack names $stack, which is not in $SRC"
fi

# $1 destination. Stages from a read-only copy of the source directory, the
# way the release image holds it.
stage_from_readonly_copy() {
  local copy="$work/ro-src"
  if [ ! -d "$copy" ]; then
    cp -R "$SRC" "$copy"
    chmod 0444 "$copy"/*
  fi
  bash "$copy/stage-resource-pack.sh" "$1"
}

dest="$work/data/resource_packs"
if stage_from_readonly_copy "$dest" 2>"$work/stage.err" \
  && cmp -s "$SRC/bbstudio_RP.mcpack" "$dest/bbstudio_RP.mcpack" \
  && cmp -s "$yml" "$dest/resource_packs.yml"; then
  pass "staging puts the pack and resource_packs.yml in the data folder byte for byte"
else
  fail "staging did not leave the pack and resource_packs.yml: $(cat "$work/stage.err")"
fi

if grep -q '^force_resources: true$' "$dest/resource_packs.yml"; then
  pass "the staged resource_packs.yml forces the stack"
else
  fail "the staged resource_packs.yml does not force the stack"
fi

printf 'stale\n' > "$dest/resource_packs.yml"
chmod 0444 "$dest/bbstudio_RP.mcpack"
if stage_from_readonly_copy "$dest" 2>"$work/stage.err" \
  && cmp -s "$yml" "$dest/resource_packs.yml" \
  && cmp -s "$SRC/bbstudio_RP.mcpack" "$dest/bbstudio_RP.mcpack"; then
  pass "a second boot restores a changed resource_packs.yml and replaces a read-only pack"
else
  fail "a second boot did not restore the staged files: $(cat "$work/stage.err")"
fi

tampered="$work/tampered"
cp -R "$SRC" "$tampered"
printf 'x' >> "$tampered/bbstudio_RP.mcpack"
if out="$(bash "$tampered/stage-resource-pack.sh" "$work/tampered-data" 2>&1)"; then
  fail "a pack that differs from its sha256 was staged"
elif grep -qF "differs from bbstudio_RP.mcpack.sha256" <<<"$out"; then
  pass "a pack that differs from its sha256 is refused naming the sha256 file"
else
  fail "a tampered pack was refused without saying why: $out"
fi
if [ ! -e "$work/tampered-data" ]; then
  pass "a refused pack leaves the data folder untouched"
else
  fail "a refused pack still created $work/tampered-data"
fi

missing="$work/missing"
cp -R "$SRC" "$missing"
rm "$missing/resource_packs.yml"
if out="$(bash "$missing/stage-resource-pack.sh" "$work/missing-data" 2>&1)"; then
  fail "a missing resource_packs.yml was accepted"
elif grep -qF "resource_packs.yml is missing or empty" <<<"$out"; then
  pass "a missing resource_packs.yml is refused naming the file"
else
  fail "a missing resource_packs.yml was refused without saying why: $out"
fi

# The pack must be listed in no place that would load it as a plugin.
if [ ! -e "$DIR/plugins/resource_packs/plugin.yml" ]; then
  pass "the resource_packs folder is not a plugin source folder"
else
  fail "plugins/resource_packs/plugin.yml exists, so start-instance.sh would load the folder as a plugin"
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
printf 'all %s assertions passed: the pack is the pinned bytes, forced, and staged on every boot.\n' "$PASSES"
