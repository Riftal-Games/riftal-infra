#!/usr/bin/env bash
# Boots the pinned core image with start-instance.sh as compose runs it for
# `instance`, through the three outcomes a clone can be in (riftal-infra#228):
# RiftalMines.phar unbuilt, built with no MYSQL_ROOT_PASSWORD, and built with
# one. selftest.sh beside this pins the script with php stubbed; only a real
# boot shows PocketMine loading the copied roster and reading the config
# rendered onto a fresh /data as uid 1000.
#
# RiftalMines itself lives in the private riftal-game, which CI cannot check
# out, and it connects to MySQL on enable. A stand-in phar of the same name
# takes its place and logs the password PocketMine hands it from that config.
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
EXPECTED_ASSERTIONS=3
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
		$password = $this->getConfig()->getNested("database.password");
		$this->getLogger()->info("mines-standin password=" . var_export($password, true));
	}
}
SRC);
PHP
if ! timeout 120 docker run --rm --pull never -m 1g --cpus 1 -v "$work/phar:/out" \
    "$IMAGE" php -dphar.readonly=0 /out/build.php \
    || [ ! -s "$work/phar/RiftalMines.phar" ]; then
  printf '::error::could not build the stand-in RiftalMines.phar\n'
  exit 1
fi

# $1 "built" to put the stand-in phar beside start-instance.sh, the rest
# docker run flags. Sets LOG to the container's output and RC to its exit code.
boot() {
  local plugins="$work/plugins-$RANDOM" name="riftal_selftest_instance_boot_$$_$RANDOM"
  mkdir -p "$plugins/instance-only"
  cp "$work/BootProbe.php" "$plugins/"
  cp "$DIR/start-instance.sh" "$DIR/render-config.sh" \
    "$DIR/RiftalMines.config.yml.template" "$plugins/instance-only/"
  if [ "$1" = built ]; then
    cp "$work/phar/RiftalMines.phar" "$plugins/instance-only/"
  fi
  shift
  chmod -R a+rX "$plugins"
  RC=0
  LOG="$(timeout 180 docker run --rm --pull never --name "$name" -m 2g --cpus 2 \
      -v "$plugins:/plugins:ro" "$@" \
      -e "POCKETMINE_ARGS=--auto-report.enabled=0 --level-type=flat" \
      "$IMAGE" bash /plugins/instance-only/start-instance.sh 2>&1)" || RC=$?
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
boot unbuilt
why="$(loaded BootProbe)"
[ -z "$why" ] && pass "an unbuilt phar is skipped and the instance reaches Done" \
  || fail "the unbuilt boot: $why"

printf '\n== built with no MYSQL_ROOT_PASSWORD: refuses before PocketMine starts\n'
boot built
if [ "$RC" -ne 0 ] && grep -q 'MYSQL_ROOT_PASSWORD is not set' <<<"$LOG" \
    && ! grep -q 'Starting Minecraft' <<<"$LOG"; then
  pass "the boot stops before php, naming MYSQL_ROOT_PASSWORD"
else
  fail "expected a refusal naming MYSQL_ROOT_PASSWORD before PocketMine, got exit $RC: $(tail -n 20 <<<"$LOG")"
fi

printf '\n== built with a password: RiftalMines loads and reads it from /data\n'
boot built -e "MYSQL_ROOT_PASSWORD=$PASSWORD"
why="$(loaded BootProbe,RiftalMines)"
if [ -z "$why" ] && ! grep -qF "mines-standin password='$PASSWORD'" <<<"$LOG"; then
  why="expected the rendered password, got: $(grep -o 'mines-standin password=.*' <<<"$LOG" || printf none)"
fi
[ -z "$why" ] && pass "RiftalMines loads from the roster with the password rendered onto /data" \
  || fail "the built boot: $why"

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
printf 'all %s assertions passed: start-instance.sh boots the pinned core image in all three states.\n' "$PASSES"
