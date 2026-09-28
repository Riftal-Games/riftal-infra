<?php

/**
 * @name JoinOrderProbe
 * @main riftal\dev\joinorder\Main
 * @version 0.0.1
 * @api 5.0.0
 * @depend RiftalDevBots
 * @description Self-test fixture for selftest.sh beside it. Never loaded by a stack.
 */

declare(strict_types=1);

namespace riftal\dev\joinorder;

use pocketmine\entity\Skin;
use pocketmine\event\EventPriority;
use pocketmine\event\HandlerListManager;
use pocketmine\event\Listener;
use pocketmine\event\player\PlayerJoinEvent;
use pocketmine\event\player\PlayerPreLoginEvent;
use pocketmine\math\Vector3;
use pocketmine\player\Player;
use pocketmine\player\PlayerInfo;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\Server;
use pocketmine\world\World;
use Ramsey\Uuid\Uuid;
use function count;
use function implode;
use function sprintf;
use function str_repeat;

/**
 * Stands in for a joining bot without a network session. It is built without
 * its constructor, so it overrides everything the join handlers under test
 * call on it, and records each teleport instead of moving anything.
 */
class ProbePlayer extends Player{

	/** @var list<Vector3> */
	public static array $teleports = [];

	public function getName() : string{
		return Main::BOT_NAME;
	}

	public function getId() : int{
		return 1;
	}

	public function getWorld() : World{
		return Server::getInstance()->getWorldManager()->getDefaultWorld();
	}

	public function teleport(Vector3 $pos, ?float $yaw = null, ?float $pitch = null) : bool{
		self::$teleports[] = $pos->asVector3();
		return true;
	}

	public function __destruct(){
	}
}

/**
 * Places joining players the way RiftalMines' JoinSpawnListener does: through
 * registerEvents() with no @priority tag, so at NORMAL.
 */
final class Placer implements Listener{

	public function onJoin(PlayerJoinEvent $event) : void{
		$event->getPlayer()->teleport(Main::placement());
	}
}

final class Main extends PluginBase{

	public const BOT_NAME = "JoinOrderProbe";

	public static function placement() : Vector3{
		return Server::getInstance()->getWorldManager()->getDefaultWorld()->getSafeSpawn()->add(20, 0, 20);
	}

	protected function onEnable() : void{
		$this->getServer()->getPluginManager()->registerEvents(new Placer(), $this);
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask($this->probe(...)), 1);
	}

	private function probe() : void{
		$logger = $this->getLogger();
		$names = [
			EventPriority::LOWEST => "LOWEST",
			EventPriority::LOW => "LOW",
			EventPriority::NORMAL => "NORMAL",
			EventPriority::HIGH => "HIGH",
			EventPriority::HIGHEST => "HIGHEST",
			EventPriority::MONITOR => "MONITOR",
		];
		$list = HandlerListManager::global()->getListFor(PlayerJoinEvent::class);
		foreach(EventPriority::ALL as $priority){
			foreach($list->getListenersByPriority($priority) as $listener){
				$logger->info("join-order-probe handler " . $names[$priority] . " " . $listener->getPlugin()->getName());
			}
		}

		$info = new PlayerInfo(
			self::BOT_NAME,
			Uuid::uuid4(),
			new Skin("Standard_Custom", str_repeat("\x00", 64 * 32 * 4)),
			"en_US",
			["DeviceModel" => "riftal-devbot"]
		);
		$preLogin = new PlayerPreLoginEvent($info, "127.0.0.1", 19132, false);
		$preLogin->call();

		$player = (new \ReflectionClass(ProbePlayer::class))->newInstanceWithoutConstructor();
		(new PlayerJoinEvent($player, ""))->call();

		$spawn = $player->getWorld()->getSafeSpawn();
		$placement = self::placement();
		$seen = [];
		foreach(ProbePlayer::$teleports as $pos){
			$seen[] = $pos->equals($spawn) ? "spawn" : ($pos->equals($placement) ? "placer" : "elsewhere");
		}
		$logger->info(sprintf(
			"join-order-probe admitted=%s teleports=%s",
			$preLogin->isAllowed() ? "yes" : "no",
			count($seen) === 0 ? "none" : implode(",", $seen)
		));
		$this->getServer()->shutdown();
	}
}
