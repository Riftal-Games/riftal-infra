#!/usr/bin/env bash
# Boots the pinned core image with start-instance.sh, the last command in the
# `instance` service's chain, run directly without the require-* checks and
# the index delivery compose puts in front of it unless a boot says it runs
# that too, through the three outcomes a clone can be in (riftal-infra#228):
# RiftalMines.phar unbuilt, built with no RIFTAL_DB_PASSWORD_MINES, and built
# with one. RiftalGangs.phar is then built, with its index delivered, with none
# mounted, and with no password (riftal-infra#697). selftest.sh beside this pins
# the script with php stubbed; only a real boot shows PocketMine loading the
# copied roster and reading the config rendered onto a fresh /data as uid 1000.
#
# RiftalMines and RiftalGangs live in the private riftal-game, which CI cannot
# check out, and RiftalMines connects to MySQL on enable. A stand-in phar of the
# same name takes each place. The Mines one logs the password in its config, the
# password in its environment, and how many files under /data/plugin_data hold
# the latter. The Gangs one logs the sha1 of the index in its data folder and
# disables itself when it has none, as the real plugin does.
# BootProbe, a script plugin in the shared /plugins, logs the enabled plugins
# once the server is up and shuts it down cleanly.
#
# Publishes no port and keeps nothing: /plugins is a scratch copy mounted
# read-only and /data is the container's own anonymous volume, removed with it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../core-image.sh"
core_image || { printf 'the instance boot was never checked\n'; exit 1; }
IMAGE="$CORE_IMAGE"
PASSWORD='selftest-a/b+c&d='

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=7
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/BootProbe.php" <<'PHP'
<?php

/**
 * @name BootProbe
 * @main riftal\dev\bootprobe\Main
 * @version 0.0.1
 * @api 5.0.0
 */

declare(strict_types=1);

namespace riftal\dev\bootprobe;

use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;

class Main extends PluginBase{
	protected function onEnable() : void{
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask(function() : void{
			$names = [];
			foreach($this->getServer()->getPluginManager()->getPlugins() as $plugin){
				if($plugin->isEnabled()){
					$names[] = $plugin->getName();
				}
			}
			sort($names);
			$this->getLogger()->info("boot-probe enabled=" . implode(",", $names));
			$this->getServer()->shutdown();
		}), 1);
	}
}
PHP

mkdir -m 0777 "$work/phar"
cat > "$work/phar/build.php" <<'PHP'
<?php
$phar = new Phar("/out/RiftalMines.phar");
$phar->addFromString("plugin.yml", "name: RiftalMines\nmain: riftal\\dev\\minesstandin\\Main\nversion: 0.0.1\napi: 5.0.0\n");
$phar->addFromString("src/riftal/dev/minesstandin/Main.php", <<<'SRC'
<?php
declare(strict_types=1);
namespace riftal\dev\minesstandin;
class Main extends \pocketmine\plugin\PluginBase{
	protected function onEnable() : void{
		$configured = $this->getConfig()->getNested("database.password");
		$environment = getenv("RIFTAL_DB_PASSWORD_MINES");
		$held = 0;
		if(is_string($environment) && $environment !== ""){
			$files = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator("/data/plugin_data", \FilesystemIterator::SKIP_DOTS));
			foreach($files as $file){
				if($file->isFile() && str_contains((string) file_get_contents($file->getPathname()), $environment)){
					$held++;
				}
			}
		}
		$this->getLogger()->info("mines-standin configured=" . var_export($configured, true) . " environment=" . var_export($environment, true) . " files-holding-it=" . $held);
	}
}
SRC);
$phar = new Phar("/out/RiftalGangs.phar");
$phar->addFromString("plugin.yml", "name: RiftalGangs\nmain: riftal\\dev\\gangsstandin\\Main\nversion: 0.0.1\napi: 5.0.0\n");
$phar->addFromString("src/riftal/dev/gangsstandin/Main.php", <<<'SRC'
<?php
declare(strict_types=1);
namespace riftal\dev\gangsstandin;
class Main extends \pocketmine\plugin\PluginBase{
	protected function onEnable() : void{
		$file = $this->getDataFolder() . "world_index.json";
		$index = @file_get_contents($file);
		if($index === false){
			$this->getLogger()->error("disabling, config or environment error: gangs: cannot read world index \"$file\"");
			$this->getServer()->getPluginManager()->disablePlugin($this);
			return;
		}
		$this->getLogger()->info("gangs-standin index=" . sha1($index) . " username=" . var_export($this->getConfig()->getNested("database.username"), true));
	}
}
SRC);
PHP
if ! timeout 120 docker run --rm --pull never -m 1g --cpus 1 -v "$work/phar:/out" \
    "$IMAGE" php -dphar.readonly=0 /out/build.php \
    || [ ! -s "$work/phar/RiftalMines.phar" ] || [ ! -s "$work/phar/RiftalGangs.phar" ]; then
  printf '::error::could not build the stand-in RiftalMines.phar and RiftalGangs.phar\n'
  exit 1
fi

# The designer's index, which deliver-world-index.sh copies into RiftalGangs'
# data folder when it is mounted at /etc/riftal and the chain below runs it.
printf '{"worlds":[{"name":"contested","role":"contested"}]}\n' > "$work/world_index.json"
INDEX_MOUNT=(-v "$work/world_index.json:/etc/riftal/world_index.json:ro")

# $1 the phar to put beside start-instance.sh: "unbuilt" for none, "built" for
# RiftalMines, "gangs" for RiftalGangs. Every boot copies RiftalGangs.config.yml
# beside it, built or not. $2 "deliver" to run deliver-world-index.sh ahead of
# it, as compose does, or "direct" to run start-instance.sh alone. The rest are
# docker run flags. Sets LOG to the container's output and RC to its exit code.
boot() {
  local plugins="$work/plugins-$RANDOM" name="riftal_selftest_instance_boot_$$_$RANDOM"
  local chain=(bash /plugins/instance-only/start-instance.sh) built="$1"
  mkdir -p "$plugins/instance-only"
  cp "$work/BootProbe.php" "$plugins/"
  cp "$DIR/start-instance.sh" "$DIR/render-config.sh" "$DIR/RiftalGangs.config.yml" \
    "$DIR/RiftalMines.config.yml.template" "$plugins/instance-only/"
  cp "$DIR/../deliver-world-index.sh" "$plugins/"
  if [ "$built" = built ]; then
    cp "$work/phar/RiftalMines.phar" "$plugins/instance-only/"
  elif [ "$built" = gangs ]; then
    cp "$work/phar/RiftalGangs.phar" "$plugins/instance-only/"
  fi
  if [ "$2" = deliver ]; then
    chain=(bash /plugins/deliver-world-index.sh "${chain[@]}")
  fi
  shift 2
  chmod -R a+rX "$plugins"
  RC=0
  LOG="$(timeout 180 docker run --rm --pull never --name "$name" -m 2g --cpus 2 \
      -v "$plugins:/plugins:ro" "$@" \
      -e "POCKETMINE_ARGS=--auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" "${chain[@]}" 2>&1)" || RC=$?
  if [ "$RC" -eq 124 ]; then
    docker stop -t 60 "$name" >/dev/null 2>&1 || true
  fi
}

# $1 the plugins BootProbe must see enabled. Prints what is wrong with LOG,
# nothing when the server reached Done with exactly those and no error.
loaded() {
  local errors
  errors="$(grep -E '/(ERROR|CRITICAL|EMERGENCY)\]|Exception|Stack trace' <<<"$LOG" || true)"
  if [ "$RC" -ne 0 ]; then
    printf 'exit %s\n%s\n' "$RC" "$(tail -n 20 <<<"$LOG")"
  elif [ -n "$errors" ]; then
    printf 'server log has an error:\n%s\n' "$errors"
  elif ! grep -q 'Done (' <<<"$LOG"; then
    printf 'never reached Done\n%s\n' "$(tail -n 20 <<<"$LOG")"
  elif ! grep -q "boot-probe enabled=$1\$" <<<"$LOG"; then
    printf 'expected enabled=%s, got: %s\n' "$1" "$(grep -o 'boot-probe enabled=.*' <<<"$LOG" || printf none)"
  fi
}

printf '\n== RiftalMines.phar unbuilt: boots without it and needs no password\n'
boot unbuilt direct
why="$(loaded BootProbe)"
[ -z "$why" ] && pass "an unbuilt phar is skipped and the instance reaches Done" \
  || fail "the unbuilt boot: $why"

# $1 the assertion's name, the rest docker run flags. Passes when the built
# boot stops before PocketMine and names RIFTAL_DB_PASSWORD_MINES.
refuses() {
  local label="$1"
  shift
  boot built direct "$@"
  if [ "$RC" -ne 0 ] && grep -q 'RIFTAL_DB_PASSWORD_MINES is not set' <<<"$LOG" \
      && ! grep -q 'Starting Minecraft' <<<"$LOG"; then
    pass "$label: the boot stops before php, naming RIFTAL_DB_PASSWORD_MINES"
  else
    fail "$label: expected a refusal naming RIFTAL_DB_PASSWORD_MINES before PocketMine, got exit $RC: $(tail -n 20 <<<"$LOG")"
  fi
}

printf '\n== built with no RIFTAL_DB_PASSWORD_MINES: refuses before PocketMine starts\n'
refuses "no variables"

printf '\n== built with only MYSQL_ROOT_PASSWORD: the root password does not stand in\n'
refuses "root password only" -e "MYSQL_ROOT_PASSWORD=$PASSWORD"

printf '\n== built with RIFTAL_DB_PASSWORD_MINES: RiftalMines loads and reads it from the environment\n'
boot built direct -e "RIFTAL_DB_PASSWORD_MINES=$PASSWORD"
why="$(loaded BootProbe,RiftalMines)"
if [ -z "$why" ] && ! grep -qF "mines-standin configured='' environment='$PASSWORD' files-holding-it=0" <<<"$LOG"; then
  why="expected an empty configured password, the environment's, and no file holding it, got: $(grep -o 'mines-standin .*' <<<"$LOG" || printf none)"
fi
[ -z "$why" ] && pass "RiftalMines loads from the roster with the password from the environment and none on /data" \
  || fail "the built boot: $why"

printf '\n== RiftalGangs built, index delivered: it enables from /data/plugin_data/RiftalGangs/world_index.json (riftal-infra#697)\n'
boot gangs deliver "${INDEX_MOUNT[@]}" -e RIFTAL_DB_PASSWORD_GANGS="$PASSWORD"
why="$(loaded BootProbe,RiftalGangs)"
sent="$(sha1sum < "$work/world_index.json" | cut -d' ' -f1)"
if [ -z "$why" ] && ! grep -qF "gangs-standin index=$sent username='gangs'" <<<"$LOG"; then
  why="expected the delivered index's sha1 and the gangs login, got: $(grep -o 'gangs-standin .*' <<<"$LOG" || printf none)"
fi
[ -z "$why" ] && pass "RiftalGangs enables from the delivered index with the tracked config" \
  || fail "the delivered-index boot: $why"

printf '\n== RiftalGangs built, no index mounted: it refuses to enable\n'
boot gangs direct -e RIFTAL_DB_PASSWORD_GANGS="$PASSWORD"
if grep -qF '[RiftalGangs] disabling, config or environment error: gangs: cannot read world index "/data/plugin_data/RiftalGangs/world_index.json"' <<<"$LOG" \
    && grep -qF "Could not enable plugin 'RiftalGangs'" <<<"$LOG" && ! grep -q 'Done (' <<<"$LOG"; then
  pass "RiftalGangs refuses to enable without the delivered index, and the server stops before Done"
else
  fail "expected RiftalGangs to refuse to enable without its index, got exit $RC: $(tail -n 20 <<<"$LOG")"
fi

printf '\n== RiftalGangs built with no RIFTAL_DB_PASSWORD_GANGS: refuses before PocketMine starts\n'
boot gangs deliver "${INDEX_MOUNT[@]}"
if [ "$RC" -ne 0 ] && grep -q 'RIFTAL_DB_PASSWORD_GANGS is not set' <<<"$LOG" \
    && ! grep -q 'Starting Minecraft' <<<"$LOG"; then
  pass "no password: the boot stops before php, naming RIFTAL_DB_PASSWORD_GANGS"
else
  fail "expected a refusal naming RIFTAL_DB_PASSWORD_GANGS before PocketMine, got exit $RC: $(tail -n 20 <<<"$LOG")"
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
printf 'all %s assertions passed: start-instance.sh boots the pinned core image in every state.\n' "$PASSES"
