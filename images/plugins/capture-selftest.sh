#!/usr/bin/env bash
# Self-test for RiftalCapture.php (riftal-infra#534, ADR 015 items 1, 2 and 8).
# Loads the shipped plugin in php:8.3-cli-alpine, the "Lint PHP plugins" image,
# with stubs for the PocketMine and Symfony members it calls, so Main runs whole
# against a fake server and one run of its repeating task is one tick. Each case
# prints "ok <what>" or "FAIL <what>"; the count catches a case that never ran.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$SCRIPT_DIR/RiftalCapture.php"
EXPECTED_ASSERTIONS=19

output="$(docker run --rm -i -v "$PLUGIN:/plugin.php:ro" php:8.3-cli-alpine php <<'PHP' 2>&1
<?php
namespace pocketmine\plugin{
	abstract class PluginBase{
		public function __construct(private object $server, private object $logger, private object $scheduler){}
		public function getServer() : object{ return $this->server; }
		public function getLogger() : object{ return $this->logger; }
		public function getScheduler() : object{ return $this->scheduler; }
	}
}
namespace pocketmine\scheduler{
	final class ClosureTask{ public function __construct(public \Closure $run){} }
}
namespace Symfony\Component\Filesystem{
	final class Path{
		public static function join(string ...$parts) : string{ return implode("/", $parts); }
		public static function getDirectory(string $path) : string{ return dirname($path); }
	}
}
namespace{
require "/plugin.php";
use pocketmine\scheduler\ClosureTask;
use riftal\capture\CaptureRequest;
use riftal\capture\Lease;
use riftal\capture\Main;
use riftal\capture\Stage;

function check(bool $ok, string $what) : void{
	echo ($ok ? "ok " : "FAIL ") . $what . "\n";
}

/** A players directory holding one file that cannot be read. */
final class NoCopy{
	public $context;
	private array $names = ["p.dat"];
	public function url_stat(string $path, int $flags) : array{ return ["mode" => $path === "nocopy://players" ? 0040755 : 0100644]; }
	public function dir_opendir(string $path, int $options) : bool{ return true; }
	public function dir_readdir() : string|false{ return array_shift($this->names) ?? false; }
	public function dir_closedir() : bool{ return true; }
	public function stream_open(string $path, string $mode, int $options, ?string &$opened) : bool{ return false; }
}
stream_wrapper_register("nocopy", NoCopy::class);
$r = CaptureRequest::parse("20260929T0600-1 1700000900\n");
check($r !== null && $r->id === "20260929T0600-1" && $r->deadline === 1700000900, "a well-formed request parses to its id and deadline");

$bad = ["../x 1", ".. 1", ". 1", "a/b 1", "x", "x 1 2", "", "x -1", " x 1", "x 1\n\n"];
$parsed = array_filter($bad, fn(string $s) => CaptureRequest::parse($s) !== null);
check($parsed === [], "no request naming a path outside .capture, or malformed, parses: " . implode("|", $parsed));

$a = new CaptureRequest("a", 100);
$lease = new Lease();
check($lease->mayCapture($a, 50) && !$lease->mustRelease($a, 50), "a new live request is captured, and nothing is released");
$lease->hold($a);
check(!$lease->mayCapture($a, 60) && !$lease->mustRelease($a, 60), "a held request before its deadline is neither captured again nor released");
check($lease->mustRelease(new CaptureRequest("a", 900), 100), "rewriting the held id with a later deadline does not extend the lease");
check($lease->mustRelease(null, 60), "the request going away releases");
check($lease->mustRelease(new CaptureRequest("b", 900), 60), "a request naming another id releases");
check($lease->release() === "a" && $lease->release() === null, "release names the held id once");
check(!$lease->mayCapture(new CaptureRequest("a", 900), 101), "an id already captured is never captured again");
check($lease->mayCapture(new CaptureRequest("b", 900), 101) && !$lease->mayCapture(new CaptureRequest("c", 101), 101), "another id is captured, one past its deadline is not");

$root = sys_get_temp_dir() . "/cap-" . getmypid();
mkdir("$root/players/sub", 0755, true);
mkdir("$root/.capture/old/players", 0755, true);
file_put_contents("$root/.capture/old/ack", "old\n");
Stage::clear("$root/.capture");
check(is_dir("$root/.capture") && scandir("$root/.capture") === [".", ".."], "leftovers of an earlier run are cleared, the root stays");

file_put_contents("$root/players/alice.dat", random_bytes(4096));
file_put_contents("$root/players/bob.dat", "");
file_put_contents("$root/players/sub/x", "not a player file");
$count = Stage::write("$root/players", "$root/.capture", "r1");
$staged = "$root/.capture/r1";
check($count === 2
	&& file_get_contents("$staged/players/alice.dat") === file_get_contents("$root/players/alice.dat")
	&& file_get_contents("$staged/players/bob.dat") === ""
	&& !file_exists("$staged/players/sub")
	&& file_get_contents("$staged/ack") === "r1\n"
	&& !file_exists("$staged/ack.tmp"), "every player file is staged byte for byte, and the ack holds the id");
foreach(["$root/missing" => "an unreadable players directory", "nocopy://players" => "a player file that cannot be copied"] as $players => $what){
	try{
		Stage::write($players, "$root/.capture", "r2");
		$threw = false;
	}catch(\RuntimeException $e){
		$threw = true;
	}
	check($threw && !file_exists("$root/.capture/r2/ack"), "$what throws and writes no ack");
}

$worlds = new class{
	public bool $on = true;
	public function getAutoSave() : bool{ return $this->on; }
	public function setAutoSave(bool $on) : void{ $this->on = $on; $GLOBALS["events"][] = "autosave " . ($on ? "on" : "off"); }
	public function getWorlds() : array{ return [new class{ public function save(bool $force) : void{ $GLOBALS["events"][] = "world save"; } }]; }
};
$server = new class{
	public function getWorldManager() : object{ return $GLOBALS["worlds"]; }
	public function getDataPath() : string{ return $GLOBALS["root"]; }
	public function getOnlinePlayers() : array{ return [new class{ public function save() : void{ $GLOBALS["events"][] = "player save"; file_put_contents($GLOBALS["root"] . "/players/p.dat", "saved"); } }]; }
};
$scheduler = new class{
	public array $repeating = [], $delayed = [];
	public function scheduleRepeatingTask(ClosureTask $task, int $period) : void{ $this->repeating[] = $task; }
	public function scheduleDelayedTask(ClosureTask $task, int $delay) : void{ $this->delayed[] = $task; }
	public function tick() : void{
		[$due, $this->delayed] = [$this->delayed, []];
		foreach([...$due, ...$this->repeating] as $task){ ($task->run)(); }
	}
};
$logger = new class{ public function __call(string $level, array $args) : void{} };
$tick = function(?string $id) use ($scheduler) : void{
	$id === null ? unlink("/capture/request") : file_put_contents("/capture/request", "$id " . (time() + 600) . "\n");
	$scheduler->tick();
};
mkdir("/capture");
$main = new Main($server, $logger, $scheduler);
(fn() => $this->onEnable())->call($main);
check(scandir("$root/.capture") === [".", ".."], "enabling clears the r1 and r2 an earlier run left in .capture");
$events = [];
$tick("m1");
check($events === ["autosave off", "player save", "world save"]
	&& @file_get_contents("$root/.capture/m1/players/p.dat") === "saved"
	&& @file_get_contents("$root/.capture/m1/ack") === "m1\n", "one poll turns autosave off, saves players then worlds, and stages and acks the saved files in that tick");
$tick(null);
check($worlds->on && !file_exists("$root/.capture/m1"), "releasing restores autosave on and removes the staged copy");
$worlds->on = false;
$tick("m2");
$tick(null);
check(!$worlds->on && !file_exists("$root/.capture/m2"), "a hold taken under an operator's save-off releases with autosave still off");
$worlds->on = true;
$tick("m3");
(fn() => $this->onDisable())->call($main);
check($worlds->on && !file_exists("$root/.capture/m3"), "disabling during a hold restores autosave before the worlds unload");
}
PHP
)" || true

printf '%s\n' "$output"
passes="$(grep -c '^ok ' <<<"$output" || true)"
failures="$(grep -c '^FAIL ' <<<"$output" || true)"
ran=$((passes + failures))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '::error::%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$failures" -ne 0 ]; then
  printf '::error::%s self-test assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all %s assertions passed: requests parse safely, a lease is taken once and never extended, one tick saves then stages and acks, and release restores autosave.\n' "$passes"
