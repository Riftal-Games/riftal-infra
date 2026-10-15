<?php

/**
 * @name JoinOrderProbe
 * @main riftal\dev\joinorder\Main
 * @version 0.0.4
 * @api 5.0.0
 * @loadbefore RiftalDevBots
 * @description Self-test fixture for selftest.sh beside it. Never loaded by a stack.
 */

/*
 * Loading first registers Placer before RiftalDevBots' join handler, so at a
 * priority tie Placer runs first and the spawn return lands last. A tie is
 * then a failure the self-test sees, not one plugin load order hides.
 */

declare(strict_types=1);

namespace riftal\dev\joinorder;

use pocketmine\entity\Skin;
use pocketmine\event\entity\EntityTeleportEvent;
use pocketmine\event\EventPriority;
use pocketmine\event\HandlerListManager;
use pocketmine\event\Listener;
use pocketmine\event\player\PlayerJoinEvent;
use pocketmine\event\player\PlayerLoginEvent;
use pocketmine\event\player\PlayerPreLoginEvent;
use pocketmine\math\Vector3;
use pocketmine\player\Player;
use pocketmine\player\PlayerInfo;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\Server;
use pocketmine\world\Position;
use pocketmine\world\World;
use Ramsey\Uuid\Uuid;
use function count;
use function implode;
use function sprintf;
use function str_repeat;

/**
 * Stands in for a joining bot without a network session. It is built without
 * its constructor, so it overrides everything the handlers under test call on
 * it. A teleport fires the EntityTeleportEvent a real one fires, and is
 * recorded instead of moving anything.
 */
class ProbePlayer extends Player{

	/** @var list<array{int, Vector3}> */
	public static array $teleports = [];

	public int $probeId = 1;

	public function getName() : string{
		return Main::BOT_NAME;
	}

	public function getId() : int{
		return $this->probeId;
	}

	public function getWorld() : World{
		return Server::getInstance()->getWorldManager()->getDefaultWorld();
	}

	public function teleport(Vector3 $pos, ?float $yaw = null, ?float $pitch = null) : bool{
		$world = $this->getWorld();
		$event = new EntityTeleportEvent($this, $world->getSafeSpawn(), Position::fromObject($pos, $world));
		$event->call();
		if($event->isCancelled()){
			return false;
		}
		self::$teleports[] = [$this->probeId, $pos->asVector3()];
		return true;
	}

	public function __destruct(){
	}
}

/**
 * Places players the way riftal-game plugins do: through registerEvents()
 * with no @priority tag, so at NORMAL. The join placement stands in for
 * RiftalMines' JoinSpawnListener, the login placement for ranks' login-spawn
 * teleport (riftal-game#222).
 */
final class Placer implements Listener{

	public function onLogin(PlayerLoginEvent $event) : void{
		if(Main::$placer === "login"){
			$event->getPlayer()->teleport(Main::placement(Main::LOGIN_OFFSET));
		}
	}

	public function onJoin(PlayerJoinEvent $event) : void{
		if(Main::$placer === "join"){
			$event->getPlayer()->teleport(Main::placement(Main::JOIN_OFFSET));
		}
	}
}

/**
 * Refuses the login placement, as a plugin guarding where players may go
 * would. At HIGHEST it runs after a teleport watch registered at any priority
 * below MONITOR, so such a watch sees the placement before it is refused.
 */
final class Canceller implements Listener{

	/** @priority HIGHEST */
	public function onTeleport(EntityTeleportEvent $event) : void{
		if(Main::$cancelLogin && $event->getTo()->equals(Main::placement(Main::LOGIN_OFFSET))){
			$event->cancel();
		}
	}
}

final class Main extends PluginBase{

	public const BOT_NAME = "JoinOrderProbe";
	public const JOIN_OFFSET = 20;
	public const LOGIN_OFFSET = -20;
	public const RESET_OFFSET = 40;

	/** When Placer places the bot: "join", "login" or "none" */
	public static string $placer = "join";

	/** Whether Canceller refuses the login placement */
	public static bool $cancelLogin = false;

	public static function placement(int $offset) : Vector3{
		return Server::getInstance()->getWorldManager()->getDefaultWorld()->getSafeSpawn()->add($offset, 0, $offset);
	}

	protected function onEnable() : void{
		$this->getServer()->getPluginManager()->registerEvents(new Placer(), $this);
		$this->getServer()->getPluginManager()->registerEvents(new Canceller(), $this);
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

		$this->session("join-order-probe", "join");
		$this->session("login-placement-probe", "login");
		$this->session("stale-session-probe", "none", true);
		$this->session("cancelled-login-probe", "login", false, true);
		$this->session("non-bot-takeover-probe", "none", false, false, true);
		$this->getServer()->shutdown();
	}

	/**
	 * One bot session from pre-login to join, placed as $placer says. With
	 * $stale, the bot first joins as entity 1, and that stale session is
	 * teleported, as a mine reset would, after the new session's pre-login
	 * and before core kicks it as a duplicate. With $cancelLogin, Canceller
	 * refuses the login placement. With $takeover, a session that is not a
	 * bot pre-logs in under the bot's name after the bot's pre-login, and it
	 * is that session which logs in and joins. Only the new session's own
	 * teleports that went through are reported.
	 */
	private function session(string $label, string $placer, bool $stale = false, bool $cancelLogin = false, bool $takeover = false) : void{
		self::$placer = $placer;
		self::$cancelLogin = $cancelLogin;
		ProbePlayer::$teleports = [];

		$preLogin = $this->preLogin();
		if($takeover){
			$preLogin = $this->preLogin("Windows");
		}
		if($stale){
			$old = $this->login(1);
			(new PlayerJoinEvent($old, ""))->call();
			$preLogin = $this->preLogin();
			$old->teleport(self::placement(self::RESET_OFFSET));
		}
		$player = $this->login($stale ? 2 : 1);
		(new PlayerJoinEvent($player, ""))->call();

		$spawn = $player->getWorld()->getSafeSpawn();
		$placements = [
			"placer" => self::placement(self::JOIN_OFFSET),
			"login-placer" => self::placement(self::LOGIN_OFFSET),
		];
		$seen = [];
		foreach(ProbePlayer::$teleports as [$id, $pos]){
			if($id !== $player->getId()){
				continue;
			}
			$name = $pos->equals($spawn) ? "spawn" : "elsewhere";
			foreach($placements as $placer => $at){
				if($pos->equals($at)){
					$name = $placer;
				}
			}
			$seen[] = $name;
		}
		$this->getLogger()->info(sprintf(
			"%s admitted=%s teleports=%s",
			$label,
			$preLogin->isAllowed() ? "yes" : "no",
			count($seen) === 0 ? "none" : implode(",", $seen)
		));
	}

	private function preLogin(string $deviceModel = "riftal-devbot") : PlayerPreLoginEvent{
		$info = new PlayerInfo(
			self::BOT_NAME,
			Uuid::uuid4(),
			new Skin("Standard_Custom", str_repeat("\x00", 64 * 32 * 4)),
			"en_US",
			["DeviceModel" => $deviceModel]
		);
		$event = new PlayerPreLoginEvent($info, "127.0.0.1", 19132, false);
		$event->call();
		return $event;
	}

	/** A real session fires PlayerLoginEvent once its player exists. */
	private function login(int $id) : ProbePlayer{
		$player = (new \ReflectionClass(ProbePlayer::class))->newInstanceWithoutConstructor();
		$player->probeId = $id;
		(new PlayerLoginEvent($player, ""))->call();
		return $player;
	}
}
