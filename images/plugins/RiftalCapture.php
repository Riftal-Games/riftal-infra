<?php

/**
 * @name RiftalCapture
 * @main riftal\capture\Main
 * @version 0.1.0
 * @api 5.0.0
 * @softdepend RiftalCustody
 * @description Holds one tick and stages player files when the backup asks (ADR 015).
 */

declare(strict_types=1);

namespace riftal\capture;

use pocketmine\event\Listener;
use pocketmine\event\world\ChunkUnloadEvent;
use pocketmine\event\world\WorldUnloadEvent;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\scheduler\TaskHandler;
use Symfony\Component\Filesystem\Path;
use function copy;
use function file_get_contents;
use function file_put_contents;
use function hrtime;
use function is_dir;
use function is_file;
use function mkdir;
use function preg_match;
use function rename;
use function rmdir;
use function round;
use function scandir;
use function time;
use function unlink;

/**
 * The backup writes the request file whole, through a rename, as one line:
 * "<id> <deadline>", the deadline in epoch seconds. The id names a directory
 * under /data/.capture, so anything that could name a path outside it is no
 * request at all.
 */
final class CaptureRequest{

	public function __construct(
		public readonly string $id,
		public readonly int $deadline
	){}

	public static function parse(string $contents) : ?self{
		if(preg_match('/\A([A-Za-z0-9][A-Za-z0-9._-]{0,63}) ([0-9]{1,12})\n?\z/', $contents, $m) !== 1){
			return null;
		}
		return new self($m[1], (int) $m[2]);
	}

	public static function read(string $path) : ?self{
		$contents = is_file($path) ? @file_get_contents($path) : false;
		return $contents === false ? null : self::parse($contents);
	}
}

/**
 * Which request is held, and when a hold ends. Each id is held at most once
 * per process, whatever other ids were held in between, so a lease that ran
 * out is never taken up again by the same request, and the deadline is the
 * one read at capture: a request rewritten with a later deadline does not
 * extend it (ADR 015 items 2 and 8).
 */
final class Lease{

	private ?CaptureRequest $held = null;
	/** @var array<string, true> every id held in this process */
	private array $heldBefore = [];

	public function heldId() : ?string{
		return $this->held?->id;
	}

	public function mustRelease(?CaptureRequest $request, int $now) : bool{
		return $this->held !== null
			&& ($request === null || $request->id !== $this->held->id || $now >= $this->held->deadline);
	}

	public function mayCapture(?CaptureRequest $request, int $now) : bool{
		return $this->held === null && $request !== null && !isset($this->heldBefore[$request->id]) && $now < $request->deadline;
	}

	public function hold(CaptureRequest $request) : void{
		$this->held = $request;
		$this->heldBefore[$request->id] = true;
	}

	public function release() : ?string{
		$id = $this->held?->id;
		$this->held = null;
		return $id;
	}
}

/**
 * The staged copy and its ack. The ack goes in last, through a rename, so a
 * backup that sees it also sees every staged file whole.
 *
 * The ack is two lines, each ending "\n": the request id, then the time the
 * server process started, as whole microseconds since the Unix epoch. The
 * second line is the server's own start time, fixed for the life of the
 * process, so the same id acked with a different second line was staged again
 * by a restarted server (ADR 015 items 1.4 and 2).
 */
final class Stage{

	/**
	 * @param float $started the server process start time, in epoch seconds
	 * @return int the number of player files staged
	 */
	public static function write(string $players, string $root, string $id, float $started) : int{
		$dir = "$root/$id";
		self::remove($dir);
		$names = is_dir($players) ? scandir($players) : false;
		if($names === false){
			throw new \RuntimeException("cannot list $players");
		}
		if(!@mkdir("$dir/players", 0755, true)){
			throw new \RuntimeException("cannot create $dir/players");
		}
		$count = 0;
		foreach($names as $name){
			if(!is_file("$players/$name")){
				continue;
			}
			if(!@copy("$players/$name", "$dir/players/$name")){
				throw new \RuntimeException("cannot copy $players/$name");
			}
			$count++;
		}
		$micros = (int) round($started * 1e6);
		if(@file_put_contents("$dir/ack.tmp", "$id\n$micros\n") === false || !@rename("$dir/ack.tmp", "$dir/ack")){
			throw new \RuntimeException("cannot write $dir/ack");
		}
		return $count;
	}

	public static function clear(string $root) : void{
		foreach(is_dir($root) ? (scandir($root) ?: []) : [] as $name){
			if($name !== "." && $name !== ".."){
				self::remove("$root/$name");
			}
		}
	}

	public static function remove(string $path) : void{
		if(is_dir($path)){
			self::clear($path);
			@rmdir($path);
		}elseif(is_file($path)){
			@unlink($path);
		}
	}
}

/**
 * Polls the request at enable and once a second. Every step of a capture runs
 * in one call on the main thread, so in one tick: no player save can land
 * between the saves and the copy, because player files are written only on
 * the main thread.
 */
final class Main extends PluginBase implements Listener{

	private const REQUEST = "/capture/request";

	private Lease $lease;
	private bool $autoSaveBefore = true;
	private ?TaskHandler $playerSaves = null;

	protected function onEnable() : void{
		$this->lease = new Lease();
		Stage::clear($this->root());
		if(!is_dir(Path::getDirectory(self::REQUEST))){
			$this->getLogger()->warning("no " . Path::getDirectory(self::REQUEST) . " mount, so no backup can capture this instance");
		}
		$this->getServer()->getPluginManager()->registerEvents($this, $this);
		$this->getScheduler()->scheduleRepeatingTask(new ClosureTask($this->poll(...)), 20);
		$this->poll();
	}

	/**
	 * Under the hold's autosave off, core drops an unloading chunk without
	 * saving it, so a block broken in it would come back while its drops stay
	 * in an inventory. A cancelled unload stays queued, and once autosave is
	 * back the chunk unloads with its save.
	 *
	 * @priority HIGHEST
	 */
	public function onChunkUnload(ChunkUnloadEvent $event) : void{
		if($this->lease->heldId() !== null){
			$event->cancel();
		}
	}

	/**
	 * Core ignores this cancel on a forced unload, which only shutdown makes,
	 * and shutdown disables this plugin, releasing the hold, first.
	 *
	 * @priority HIGHEST
	 */
	public function onWorldUnload(WorldUnloadEvent $event) : void{
		if($this->lease->heldId() !== null){
			$event->cancel();
		}
	}

	/**
	 * Core's periodic player save runs only under its autosave flag, which the
	 * hold turns off. The backup reads the staged copy, so these saves keep a
	 * crash during the hold from losing more than one outside it (ADR 015, Why).
	 */
	private function savePlayers() : void{
		foreach($this->getServer()->getOnlinePlayers() as $player){
			if($player->spawned){
				$player->save();
			}
		}
	}

	/**
	 * A stop during a hold puts autosave back first, so the stop saves the
	 * worlds as it would have without the hold.
	 */
	protected function onDisable() : void{
		$this->release();
	}

	private function root() : string{
		return Path::join($this->getServer()->getDataPath(), ".capture");
	}

	private function poll() : void{
		$request = CaptureRequest::read(self::REQUEST);
		$now = time();
		if($this->lease->mustRelease($request, $now)){
			$this->release();
		}
		if($request !== null && $this->lease->mayCapture($request, $now)){
			$this->capture($request);
		}
	}

	private function capture(CaptureRequest $request) : void{
		$start = hrtime(true);
		$server = $this->getServer();
		$worlds = $server->getWorldManager();
		$this->autoSaveBefore = $worlds->getAutoSave();
		$worlds->setAutoSave(false);
		$this->lease->hold($request);
		$interval = $worlds->getAutoSaveInterval();
		$this->playerSaves = $this->getScheduler()->scheduleDelayedRepeatingTask(new ClosureTask($this->savePlayers(...)), $interval, $interval);

		foreach($server->getOnlinePlayers() as $player){
			$player->save();
		}
		foreach($worlds->getWorlds() as $world){
			$world->save(true);
		}
		try{
			$count = Stage::write(Path::join($server->getDataPath(), "players"), $this->root(), $request->id, $server->getStartTime());
		}catch(\RuntimeException $e){
			$this->getLogger()->error("capture $request->id not acked: " . $e->getMessage());
			$this->release();
			return;
		}
		$ms = round((hrtime(true) - $start) / 1e6, 1);
		$this->getLogger()->info("capture $request->id held: $count player files staged in {$ms}ms, lease ends at $request->deadline");
	}

	private function release() : void{
		$id = $this->lease->release();
		if($id === null){
			return;
		}
		$this->playerSaves?->cancel();
		$this->playerSaves = null;
		$this->getServer()->getWorldManager()->setAutoSave($this->autoSaveBefore);
		Stage::remove(Path::join($this->root(), $id));
		$this->getLogger()->info("capture $id released, autosave " . ($this->autoSaveBefore ? "on" : "off"));
	}
}
