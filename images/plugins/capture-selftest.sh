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
namespace pocketmine\event{
	interface Listener{}
}
namespace pocketmine\scheduler{
	final class ClosureTask{ public function __construct(public \Closure $run){} }
	final class TaskHandler{
		public bool $cancelled = false;
		public function __construct(public ClosureTask $task, public int $delay, public int $period){}
		public function cancel() : void{ $this->cancelled = true; }
	}
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
use pocketmine\scheduler\TaskHandler;
use riftal\capture\CaptureRequest;
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
/** The fake server's process start time, and the ack it gives each id. */
const STARTED = 1700000000.123456;
$ack = fn(string $id) : string => "$id\n1700000000123456\n";
$r = CaptureRequest::parse("20260929T0600-1 1700000900\n");
check($r !== null && $r->id === "20260929T0600-1" && $r->deadline === 1700000900, "a well-formed request parses to its id and deadline");

$bad = ["../x 1", ".. 1", ". 1", "a/b 1", "x", "x 1 2", "", "x -1", " x 1", "x 1\n\n"];
$parsed = array_filter($bad, fn(string $s) => CaptureRequest::parse($s) !== null);
check($parsed === [], "no request naming a path outside .capture, or malformed, parses: " . implode("|", $parsed));

$root = sys_get_temp_dir() . "/cap-" . getmypid();
mkdir("$root/players/sub", 0755, true);
mkdir("$root/.capture/old/players", 0755, true);
file_put_contents("$root/.capture/old/ack", "old\n");
Stage::clear("$root/.capture");
check(is_dir("$root/.capture") && scandir("$root/.capture") === [".", ".."], "leftovers of an earlier run are cleared, the root stays");

file_put_contents("$root/players/alice.dat", random_bytes(4096));
file_put_contents("$root/players/bob.dat", "");
file_put_contents("$root/players/sub/x", "not a player file");
$count = Stage::write("$root/players", "$root/.capture", "r1", STARTED);
$staged = "$root/.capture/r1";
check($count === 2
	&& file_get_contents("$staged/players/alice.dat") === file_get_contents("$root/players/alice.dat")
	&& file_get_contents("$staged/players/bob.dat") === ""
	&& !file_exists("$staged/players/sub")
	&& file_get_contents("$staged/ack") === $ack("r1")
	&& !file_exists("$staged/ack.tmp"), "every player file is staged byte for byte, and the ack holds the id, then the start time in microseconds");
foreach(["$root/missing" => "an unreadable players directory", "nocopy://players" => "a player file that cannot be copied"] as $players => $what){
	try{
		Stage::write($players, "$root/.capture", "r2", STARTED);
		$threw = false;
	}catch(\RuntimeException $e){
		$threw = true;
	}
	check($threw && !file_exists("$root/.capture/r2/ack"), "$what throws and writes no ack");
}

$worlds = new class{
	public bool $on = true;
	public int $interval = 6000;
	public function getAutoSaveInterval() : int{ return $this->interval; }
	public function getAutoSave() : bool{ return $this->on; }
	public function setAutoSave(bool $on) : void{ $this->on = $on; $GLOBALS["events"][] = "autosave " . ($on ? "on" : "off"); }
	/** Like World::save: nothing when autosave is off and the save is unforced, else its WorldSaveEvent's placer saves write a player file. */
	public function getWorlds() : array{ return [new class{ public function save(bool $force = false) : void{
		if($GLOBALS["worlds"]->on || $force){ $GLOBALS["events"][] = "world save"; file_put_contents($GLOBALS["root"] . "/players/w.dat", "placed"); }
	} }]; }
};
$server = new class{
	public function getWorldManager() : object{ return $GLOBALS["worlds"]; }
	public function getDataPath() : string{ return $GLOBALS["root"]; }
	public function getPluginManager() : object{ return new class{ public function registerEvents(object $listener, object $plugin) : void{} }; }
	public function getOnlinePlayers() : array{ return $GLOBALS["players"]; }
	public function getStartTime() : float{ return STARTED; }
};
$players = [new class{ public bool $spawned = true; public function save() : void{ $GLOBALS["events"][] = "player save"; file_put_contents($GLOBALS["root"] . "/players/p.dat", "saved"); } }];
$scheduler = new class{
	public array $repeating = [], $delayed = [];
	public function scheduleRepeatingTask(ClosureTask $task, int $period) : TaskHandler{ return $this->repeating[] = new TaskHandler($task, -1, $period); }
	public function scheduleDelayedRepeatingTask(ClosureTask $task, int $delay, int $period) : TaskHandler{ return $this->repeating[] = new TaskHandler($task, $delay, $period); }
	public function scheduleDelayedTask(ClosureTask $task, int $delay) : void{ $this->delayed[] = $task; }
	/** Every repeating task runs once a tick whatever its period, so one run of the player saves stands for one interval. */
	public function tick() : void{
		[$due, $this->delayed] = [$this->delayed, []];
		foreach($due as $task){ ($task->run)(); }
		foreach($this->repeating as $handler){ $handler->cancelled || ($handler->task->run)(); }
	}
	/** @return TaskHandler[] the live repeating tasks other than the 20-tick poll */
	public function others() : array{ return array_values(array_filter($this->repeating, fn(TaskHandler $h) => !$h->cancelled && $h->period !== 20)); }
};
$logger = new class{ public function __call(string $level, array $args) : void{} };
$tick = function(?string $id, int $ttl = 600) use ($scheduler) : void{
	$id === null ? unlink("/capture/request") : file_put_contents("/capture/request", "$id " . (time() + $ttl) . "\n");
	$scheduler->tick();
};
mkdir("/capture");
$main = new Main($server, $logger, $scheduler);
(fn() => $this->onEnable())->call($main);
check(scandir("$root/.capture") === [".", ".."], "enabling clears the r1 and r2 an earlier run left in .capture");
$events = [];
$tick("m0", 0);
check($events === [] && !file_exists("$root/.capture/m0"), "a request already at its deadline is not captured");
$tick("m1");
$ackM1 = @file_get_contents("$root/.capture/m1/ack");
check($events === ["autosave off", "player save", "world save"]
	&& @file_get_contents("$root/.capture/m1/players/p.dat") === "saved"
	&& @file_get_contents("$root/.capture/m1/players/w.dat") === "placed"
	&& $ackM1 === $ack("m1"), "one poll turns autosave off, saves players then worlds, and stages and acks the files both saves wrote in that tick");
$tick("e1", 3);
check(!$worlds->on && !file_exists("$root/.capture/m1") && @file_get_contents("$root/.capture/e1/ack") === $ack("e1"), "a request naming another id releases the held one and is captured in the same poll");
$tick("e1");
check(!$worlds->on && is_file("$root/.capture/e1/ack"), "rewriting the held request with a later deadline does not release it");
sleep(3);
$tick("e1");
check($worlds->on && !file_exists("$root/.capture/e1"), "the deadline read at capture ends the hold with the request still in place, restoring autosave on and removing the staged copy, and the id is not captured again");
$worlds->on = false;
$tick("m2");
$tick(null);
check(!$worlds->on && !file_exists("$root/.capture/m2"), "a hold taken under an operator's save-off releases with autosave still off");
$worlds->on = true;
$tick("m3");
(fn() => $this->onDisable())->call($main);
check($worlds->on && !file_exists("$root/.capture/m3"), "disabling during a hold restores autosave before the worlds unload");

// Core cancels a disabled plugin's tasks; what follows is a fresh enable.
$scheduler->repeating = [];
$worlds->interval = 4321;
$players[] = new class{ public bool $spawned = false; public function save() : void{ $GLOBALS["events"][] = "unspawned save"; } };
file_put_contents("/capture/request", "s1 " . (time() + 600) . "\n");
$main = new Main($server, $logger, $scheduler);
(fn() => $this->onEnable())->call($main);
$ackS1 = @file_get_contents("$root/.capture/s1/ack");
check($ackS1 === $ack("s1"), "a request live at enable is captured as the plugin enables, before its first scheduled poll");
check(explode("\n", (string) $ackM1)[1] === explode("\n", (string) $ackS1)[1] && $ackM1 === $ack("m1"),
	"captures three seconds apart in one process ack the same start time, the server's own, not the time of capture");
$saves = $scheduler->others();
check(count($saves) === 1 && $saves[0]->delay === 4321 && $saves[0]->period === 4321, "a hold saves players on the server's own autosave interval, read at capture");
$events = [];
$scheduler->tick();
check($events === ["player save"], "each run of those saves saves every spawned player and no other");
$tick(null);
$events = [];
$scheduler->tick();
check($saves[0]->cancelled && $scheduler->others() === [] && $events === [], "release stops the player saves");
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
printf 'all %s assertions passed: requests parse safely, a lease is taken once and never extended, one tick saves then stages and acks, a hold saves spawned players on the server autosave interval, and release restores autosave and stops those saves.\n' "$passes"
