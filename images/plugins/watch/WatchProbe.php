<?php

/**
 * @name WatchProbe
 * @main riftal\dev\watch\Main
 * @version 0.0.1
 * @api 5.0.0
 * @description Self-test fixture for selftest.sh beside it. Never loaded by a stack.
 */

declare(strict_types=1);

namespace riftal\dev\watch;

use pocketmine\entity\Location;
use pocketmine\entity\Skin;
use pocketmine\event\player\PlayerJoinEvent;
use pocketmine\event\player\PlayerLoginEvent;
use pocketmine\event\player\PlayerPreLoginEvent;
use pocketmine\event\player\PlayerQuitEvent;
use pocketmine\lang\Translatable;
use pocketmine\math\Vector3;
use pocketmine\network\mcpe\NetworkSession;
use pocketmine\network\mcpe\protocol\CameraInstructionPacket;
use pocketmine\network\mcpe\protocol\CameraPresetsPacket;
use pocketmine\network\mcpe\protocol\ClientboundPacket;
use pocketmine\permission\DefaultPermissions;
use pocketmine\permission\Permission;
use pocketmine\permission\PermissionManager;
use pocketmine\player\Player;
use pocketmine\player\PlayerInfo;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\Server;
use pocketmine\world\World;
use ReflectionClass;
use ReflectionProperty;
use Ramsey\Uuid\Uuid;
use RuntimeException;
use function array_fill;
use function array_unique;
use function count;
use function implode;
use function sprintf;
use function str_repeat;

/**
 * Takes the place of a client's session, recording what the core would have
 * sent it. Every session logs into one list, in the order the sends happened.
 */
final class RecordingSession extends NetworkSession{

	public bool $failing = false;

	public function __construct(private string $owner){
	}

	public function sendDataPacket(ClientboundPacket $packet, bool $immediate = false) : bool{
		$set = $packet instanceof CameraInstructionPacket ? $packet->getSet() : null;
		if($set !== null && $this->failing){
			Main::record($this->owner, "fault");
			throw new RuntimeException("probe camera fault");
		}
		if($set !== null){
			$at = $set->getCameraPosition();
			$rotation = $set->getRotation();
			Main::record($this->owner, "set", Main::describe($at, $rotation->getPitch(), $rotation->getYaw()));
		}elseif($packet instanceof CameraInstructionPacket && $packet->getClear() === true){
			Main::record($this->owner, "clear");
		}elseif($packet instanceof CameraPresetsPacket){
			Main::record($this->owner, "presets");
		}
		return true;
	}
}

/**
 * Stands in for a connected session without a socket. It is built without its
 * constructor, so it answers everything the plugin calls on it.
 */
final class ProbePlayer extends Player{

	public static int $nextId = 1;

	public string $probeName;

	public int $probeId;

	public bool $probeConnected = true;

	public string $probeDevice = "Windows";

	public RecordingSession $probeSession;

	public function getName() : string{
		return $this->probeName;
	}

	public function getId() : int{
		return $this->probeId;
	}

	public function getPlayerInfo() : PlayerInfo{
		return new PlayerInfo(
			$this->probeName,
			Uuid::uuid4(),
			new Skin("Standard_Custom", str_repeat("\x00", 64 * 32 * 4)),
			"en_US",
			["DeviceModel" => $this->probeDevice]
		);
	}

	public function getNetworkSession() : NetworkSession{
		return $this->probeSession;
	}

	public function isConnected() : bool{
		return $this->probeConnected;
	}

	public function hasPermission(Permission|string $name) : bool{
		return true;
	}

	public function sendMessage(Translatable|string $message) : void{
		Main::record($this->probeName, "says", (string) $message);
	}

	public function getWorld() : World{
		return Server::getInstance()->getWorldManager()->getDefaultWorld();
	}

	public function getLocation() : Location{
		$eyes = Main::eyes();
		return new Location($eyes->x, $eyes->y - 1.62, $eyes->z, $this->getWorld(), Main::YAW, Main::PITCH);
	}

	public function getEyePos() : Vector3{
		return Main::eyes();
	}

	public function teleport(Vector3 $pos, ?float $yaw = null, ?float $pitch = null) : bool{
		return true;
	}

	public function __destruct(){
	}
}

final class Main extends PluginBase{

	public const BOT = "WatchBot";
	public const BOT_DEVICE_MODEL = "riftal-devbot";
	public const YAW = 90.0;
	public const PITCH = 12.0;
	public const VIEWERS = ["ViewerA", "ViewerB", "ViewerC", "ViewerD"];

	/** @var list<array{string, string, string, int}> session, what it was sent, detail, server tick */
	private static array $sent = [];

	/** @var array<string, ProbePlayer> */
	private array $online = [];

	private int $step = 0;

	public static function eyes() : Vector3{
		return new Vector3(10.5, 65.62, -3.5);
	}

	public static function describe(Vector3 $at, float $pitch, float $yaw) : string{
		return sprintf("%.2f,%.2f,%.2f/%.1f,%.1f", $at->x, $at->y, $at->z, $pitch, $yaw);
	}

	public static function record(string $owner, string $kind, string $detail = "") : void{
		self::$sent[] = [$owner, $kind, $detail, Server::getInstance()->getTick()];
	}

	protected function onEnable() : void{
		$this->getScheduler()->scheduleRepeatingTask(new ClosureTask($this->run(...)), 1);
	}

	/** The core's own list, which Server::getPlayerExact() reads. */
	private function publish() : void{
		(new ReflectionProperty(Server::class, "playerList"))->setValue($this->getServer(), $this->online);
	}

	private function join(string $name, string $device = "Windows") : ProbePlayer{
		$player = (new ReflectionClass(ProbePlayer::class))->newInstanceWithoutConstructor();
		$player->probeName = $name;
		$player->probeId = ProbePlayer::$nextId++;
		$player->probeDevice = $device;
		$player->probeSession = new RecordingSession($name);
		$bot = $device === self::BOT_DEVICE_MODEL;
		if($bot){
			(new PlayerPreLoginEvent($player->getPlayerInfo(), "127.0.0.1", 19132, false))->call();
			(new PlayerLoginEvent($player, ""))->call();
		}
		$this->online[$name] = $player;
		$this->publish();
		if($bot){
			(new PlayerJoinEvent($player, ""))->call();
		}
		return $player;
	}

	private function quit(string $name) : void{
		$player = $this->online[$name];
		(new PlayerQuitEvent($player, "", ""))->call();
		$player->probeConnected = false;
		unset($this->online[$name]);
		$this->publish();
		self::record($name, "quit");
	}

	private function say(string $name, string $line) : void{
		$this->getServer()->dispatchCommand($this->online[$name], $line);
	}

	/** One step per tick, so the plugin's own repeating task runs between them. */
	private function run() : void{
		switch($this->step++){
			case 0:
				$registered = $this->getServer()->getCommandMap()->getCommand("watch") !== null;
				$user = PermissionManager::getInstance()->getPermission(DefaultPermissions::ROOT_USER);
				$granted = ($user?->getChildren()["riftal.devbots.watch"] ?? null) === true;
				$this->getLogger()->info(sprintf("watch-probe registered=%s permission=%s", $registered ? "yes" : "no", $granted ? "granted" : "missing"));
				if(!$registered){
					$this->finish();
					return;
				}
				$this->join(self::BOT, self::BOT_DEVICE_MODEL);
				foreach(self::VIEWERS as $viewer){
					$this->join($viewer)->probeSession->failing = $viewer === "ViewerB";
				}
				$this->say("ViewerA", "watch");
				$this->say("ViewerA", "watch Nobody");
				$this->say("ViewerA", "watch ViewerC");
				foreach(self::VIEWERS as $viewer){
					$this->say($viewer, "watch " . self::BOT);
				}
				return;
			case 4:
				$this->say("ViewerA", "watch");
				$this->quit("ViewerD");
				return;
			case 7:
				$this->quit(self::BOT);
				return;
			case 10:
				$this->report();
				$this->finish();
				return;
		}
	}

	/**
	 * One line per viewer: what it was sent, in order, with a run of three or
	 * more camera sets folded to set+. A viewer's sets are continuous when each
	 * came on the tick after the one before, and sit at the bot's eyes when all
	 * match its position and rotation.
	 */
	private function report() : void{
		$eyes = self::describe(self::eyes(), self::PITCH, self::YAW);
		foreach(self::VIEWERS as $viewer){
			$shape = [];
			$says = [];
			$details = [];
			$ticks = [];
			$run = 0;
			foreach([...self::$sent, ["", "end", "", 0]] as [$owner, $kind, $detail, $tick]){
				if($owner !== $viewer && $kind !== "end"){
					continue;
				}
				if($kind === "set"){
					++$run;
					$details[] = $detail;
					$ticks[] = $tick;
					continue;
				}
				if($run > 0){
					$shape[] = $run >= 3 ? "set+" : implode(",", array_fill(0, $run, "set"));
					$run = 0;
				}
				if($kind === "says"){
					$says[] = $detail;
				}elseif($kind !== "end"){
					$shape[] = $kind;
				}
			}
			$continuous = true;
			for($i = 1; $i < count($ticks); ++$i){
				$continuous = $continuous && $ticks[$i] === $ticks[$i - 1] + 1;
			}
			$this->getLogger()->info(sprintf(
				"watch-probe %s sent=%s continuous=%s eyes=%s says=%s",
				$viewer,
				implode(",", $shape),
				$continuous ? "yes" : "no",
				array_unique($details) === [$eyes] ? "yes" : (count($details) === 0 ? "none" : "no"),
				implode("|", $says)
			));
		}
	}

	private function finish() : void{
		$this->online = [];
		$this->publish();
		$this->getLogger()->info("watch-probe done");
		$this->getServer()->shutdown();
	}
}
