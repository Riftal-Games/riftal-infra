#!/usr/bin/env bash
# Self-test for seed-levels.sh (riftal-infra#337, ADR 009 item 5), run in
# containers of the pinned core image with the script ahead of PocketMine, as
# compose will chain it.
#
# The fixture source is a real level: one throwaway boot of the image
# generates a flat zone, whose folder is copied out and given a
# level-manifest.json holding the tree hash level_engine.py's own read_tree
# computes, the function `designer level build` writes its manifest with. A
# bind mount at /etc/riftal/levels/<zone> stands for the build volume's root.
#
# Every container is named for this run and removed with it. Volumes are
# created up front, so the CI label shim can stamp them, and removed on exit.
# At most one container runs at a time; no port is published.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../core-image.sh"
core_image || { printf 'the seed step was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"
ENGINE_PY="$DIR/../../designer/designer/level_engine.py"
SEED="$DIR/seed-levels.sh"
CONTENT_SHA="$(printf 'seed-levels fixture' | sha256sum | cut -d' ' -f1)"
RUN="riftal_smoke_seedlv_$$"

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=13
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1: $(tail -n 12 <<<"${LOG:-}")"; fi; }

work="$(mktemp -d)"
cleanup() {
  local ids
  ids="$(docker ps -aq --filter "name=^${RUN}_" 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker stop -t 60 $ids >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    docker rm -v $ids >/dev/null 2>&1 || true
  fi
  # Found by name, since new_volume runs in a command substitution and can
  # record nothing in this shell.
  docker volume ls -q --filter "name=${RUN}_" 2>/dev/null | grep "^${RUN}_" | xargs -r docker volume rm >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# Prints a fresh named volume's name.
new_volume() {
  local v="${RUN}_$1"
  docker volume create "$v" >/dev/null
  printf '%s' "$v"
}

# Reads the build's own read_tree out of level_engine.py without importing the
# module, which needs numpy and the bridge client. A rename or a change of its
# inputs breaks this at once.
cat > "$work/lv.py" <<'PY'
import ast, hashlib, io, json, sys, tarfile
from typing import Any

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
ns = {"hashlib": hashlib, "io": io, "json": json, "tarfile": tarfile, "Any": Any}
wanted = {"MANIFEST", "DOCS", "read_tree"}
for node in tree.body:
    names = {t.id for t in getattr(node, "targets", []) if isinstance(t, ast.Name)} | {getattr(node, "name", "")}
    if names & wanted:
        exec(compile(ast.Module([node], []), sys.argv[1], "exec"), ns)
if "read_tree" not in ns:
    sys.exit("level_engine.py has no read_tree")
digest = ns["read_tree"](sys.stdin.buffer.read())[0]
if sys.argv[2] == "tree":
    print(digest)
else:
    print(json.dumps({"content_sha256": sys.argv[3], "tree_sha256": digest}, indent=2, sort_keys=True))
PY

mkdir -m 0777 "$work/plugins"
cp "$SEED" "$work/plugins/seed-levels.sh"
cat > "$work/plugins/SeedProbe.php" <<'PHP'
<?php

/**
 * @name SeedProbe
 * @main riftal\dev\seedprobe\Main
 * @version 0.0.1
 * @api 5.0.0
 */

declare(strict_types=1);

namespace riftal\dev\seedprobe;

use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;

class Main extends PluginBase{
	protected function onEnable() : void{
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask(function() : void{
			$world = $this->getServer()->getWorldManager()->getDefaultWorld();
			$this->getLogger()->info("seed-probe world=" . $world->getFolderName() . " generator=" . $world->getProvider()->getWorldData()->getGenerator());
			$this->getServer()->shutdown();
		}), 1);
	}
}
PHP
chmod -R a+rX "$work/plugins"

# $1 flat or normal. Words of the PocketMine command, which makes the zone the
# default world and generates it on boot when its folder is absent.
server_cmd() {
  printf '%s\n' php /opt/pocketmine/PocketMine-MP.phar --no-wizard --data=/data --plugins=/plugins \
    --auto-report.enabled=0 --level-name=lumber "--level-type=$1" --level-seed=424242
}

# $1 volume at /data, $2 the zone list, $3 "server" for PocketMine as the
# command or "seed" for `true`, the rest docker run flags. Sets LOG and RC.
run_seed() {
  local volume="$1" zones="$2" mode="$3" name="${RUN}_c$RANDOM"
  local limits=(-m 1g --cpus 1) cmd=(true)
  shift 3
  if [ "$mode" = server ]; then
    limits=(-m 2g --cpus 2)
    mapfile -t cmd < <(server_cmd normal)
  fi
  RC=0
  LOG="$(timeout 180 docker run --rm --pull never --name "$name" "${limits[@]}" -w /opt/pocketmine \
      -v "$volume:/data" -v "$work/plugins:/plugins:ro" -e "RIFTAL_LEVEL_ZONES=$zones" "$@" \
      "$IMAGE" bash /plugins/seed-levels.sh "${cmd[@]}" 2>&1)" || RC=$?
  if [ "$RC" -eq 124 ]; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
}

# $1 volume, the rest the command, run read-only as the image's user.
inspect() {
  local volume="$1"
  shift
  timeout 120 docker run --rm --pull never --name "${RUN}_i$RANDOM" -m 1g --cpus 1 \
    -v "$volume:/data:ro" "$IMAGE" "$@"
}
# Hash of a whole tar of /data/worlds/$2, which covers names, modes and times
# as well as contents.
snapshot() { inspect "$1" tar -C /data/worlds -cf - "$2" | sha256sum | cut -d' ' -f1; }
tree_of() { inspect "$1" tar -C "/data/worlds/$2" -cf - . | python3 -I "$work/lv.py" "$ENGINE_PY" tree; }
listing() { inspect "$1" sh -c 'ls -A /data/worlds 2>/dev/null; true'; }

started() { grep -q 'Starting Minecraft' <<<"$LOG"; }
reached_done() { grep -q 'Done (' <<<"$LOG" && ! grep -qE '/(ERROR|CRITICAL|EMERGENCY)\]|Exception' <<<"$LOG"; }

printf '\n== fixture: one boot generates a flat zone, whose folder is copied out and given a manifest\n'
fx="$(new_volume fixture)"
mapfile -t cmd < <(server_cmd flat)
timeout 180 docker run --rm --pull never --name "${RUN}_cfixture" -m 2g --cpus 2 -w /opt/pocketmine \
  -v "$fx:/data" -v "$work/plugins:/plugins:ro" "$IMAGE" "${cmd[@]}" > "$work/fixture.log" 2>&1 \
  || { cat "$work/fixture.log"; printf '::error::the fixture level was not generated\n'; exit 1; }
grep -q 'seed-probe world=lumber generator=flat' "$work/fixture.log" \
  || { cat "$work/fixture.log"; printf '::error::the fixture boot did not generate a flat lumber\n'; exit 1; }
good="$work/good/lumber"
mkdir -p "$good"
inspect "$fx" tar -C /data/worlds/lumber -cf - . | tar -C "$good" -xf -
chmod -R a+rX "$work/good"
python3 -I "$work/lv.py" "$ENGINE_PY" manifest "$CONTENT_SHA" < <(inspect "$fx" tar -C /data/worlds/lumber -cf - .) > "$good/level-manifest.json"
chmod a+r "$good/level-manifest.json"
TREE="$(python3 -I "$work/lv.py" "$ENGINE_PY" tree < <(tar -C "$good" -cf - .))"
printf 'fixture tree_sha256=%s\n' "$TREE"
SRC=(-v "$good:/etc/riftal/levels/lumber:ro")

printf '\n== seeding an absent zone\n'
v1="$(new_volume seeded)"
run_seed "$v1" lumber seed "${SRC[@]}"
check "the first run seeds lumber and logs its content_sha256" \
  '[ "$RC" -eq 0 ] && grep -qF "seed-levels: lumber seeded at /data/worlds/lumber content_sha256=$CONTENT_SHA tree_sha256=$TREE" <<<"$LOG"'
check "the seeded folder hashes to the manifest, holds no temporary directory and is the server's own" \
  '[ "$(tree_of "$v1" lumber)" = "$TREE" ] && [ "$(listing "$v1")" = lumber ] &&
   [ "$(inspect "$v1" stat -c %u /data/worlds/lumber/level.dat)" = 1000 ]'
before="$(snapshot "$v1" lumber)"
run_seed "$v1" lumber seed "${SRC[@]}"
check "the second run logs lumber as present, seeds nothing and leaves the folder byte for byte" \
  '[ "$RC" -eq 0 ] && grep -qF "seed-levels: lumber present" <<<"$LOG" && ! grep -q "lumber seeded at" <<<"$LOG" &&
   [ "$(snapshot "$v1" lumber)" = "$before" ]'

v2="$(new_volume server)"
run_seed "$v2" lumber server "${SRC[@]}"
check "a first boot seeds lumber ahead of PocketMine, which starts and loads the seeded level" \
  '[ "$RC" -eq 0 ] && grep -q "seed-levels: lumber seeded" <<<"$LOG" && started && reached_done &&
   grep -q "seed-probe world=lumber generator=flat" <<<"$LOG"'
run_seed "$v2" lumber server "${SRC[@]}"
check "a second boot logs lumber as present, seeds nothing and loads the same level" \
  '[ "$RC" -eq 0 ] && grep -q "seed-levels: lumber present" <<<"$LOG" && ! grep -q "lumber seeded at" <<<"$LOG" && started &&
   reached_done && grep -q "seed-probe world=lumber generator=flat" <<<"$LOG"'

v3="$(new_volume empty)"
run_seed "$v3" "" seed "${SRC[@]}"
check "an empty zone list seeds nothing although a source is mounted" \
  '[ "$RC" -eq 0 ] && grep -q "no zones listed" <<<"$LOG" && [ -z "$(listing "$v3")" ]'

v4="$(new_volume other)"
run_seed "$v4" lumber seed "${SRC[@]}" -v "$good:/etc/riftal/levels/plots:ro"
check "only listed zones are seeded, though another source is mounted" \
  '[ "$RC" -eq 0 ] && [ "$(listing "$v4")" = lumber ]'

printf '\n== never overwriting\n'
v5="$(new_volume held)"
inspect_rw() { timeout 120 docker run --rm --pull never --name "${RUN}_w$RANDOM" -m 1g --cpus 1 -v "$1:/data" "$IMAGE" "${@:2}"; }
inspect_rw "$v5" sh -c 'mkdir -p /data/worlds/lumber/db && printf "held" > /data/worlds/lumber/level.dat && printf "x" > /data/worlds/lumber/db/000001.ldb'
before="$(snapshot "$v5" lumber)"
run_seed "$v5" lumber seed "${SRC[@]}"
check "a different lumber on the volume is kept byte for byte and the seed step succeeds" \
  '[ "$RC" -eq 0 ] && [ "$(snapshot "$v5" lumber)" = "$before" ] && grep -q "seed-levels: lumber present" <<<"$LOG" && ! grep -q "lumber seeded at" <<<"$LOG"'

# $1 the assertion, $2 a fresh volume, $3 what the refusal says, the rest
# docker run flags for the source.
refused() {
  local label="$1" volume="$2" says="$3"
  shift 3
  run_seed "$volume" lumber server "$@"
  check "$label: the step exits non-zero, lumber is absent and PocketMine never starts" \
    '[ "$RC" -ne 0 ] && ! started && [ -z "$(listing "$volume")" ] && grep -qF "$says" <<<"$LOG"'
}

bad="$work/bad/lumber"
mkdir -p "$work/bad"
cp -R "$good" "$work/bad/"
printf 'tampered' >> "$bad/level.dat"
refused "a source whose tree fails the manifest" "$(new_volume tampered)" "is not the one level-manifest.json names" -v "$bad:/etc/riftal/levels/lumber:ro"

refused "a missing source" "$(new_volume missing)" "level source /etc/riftal/levels/lumber is not mounted"

nomanifest="$work/nomanifest/lumber"
mkdir -p "$work/nomanifest"
cp -R "$good" "$work/nomanifest/"
rm "$nomanifest/level-manifest.json"
refused "a source with no manifest" "$(new_volume nomanifest)" "level-manifest.json is missing" -v "$nomanifest:/etc/riftal/levels/lumber:ro"

linked="$work/linked/lumber"
mkdir -p "$work/linked"
cp -R "$good" "$work/linked/"
ln -s /etc/passwd "$linked/escape"
refused "a source holding a symlink" "$(new_volume linked)" "/escape is neither a regular file nor a directory" -v "$linked:/etc/riftal/levels/lumber:ro"

run_seed "$(new_volume traversal)" "../etc" seed "${SRC[@]}"
check "a zone name that is not a plain name is refused" '[ "$RC" -ne 0 ] && grep -q "not a plain name" <<<"$LOG"'

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
printf 'all %s assertions passed: seed-levels.sh seeds an absent zone once, never overwrites, and stops the boot on a bad source.\n' "$PASSES"
