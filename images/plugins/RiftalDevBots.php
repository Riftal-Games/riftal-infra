<?php

/**
 * @name RiftalDevBots
 * @main riftal\dev\bots\Main
 * @version 0.2.0
 * @api 5.0.0
 * @description Dev stack only. Admits the headless player bots from devtools/bot, and lets a player watch through a bot's eyes.
 */

declare(strict_types=1);

namespace riftal\dev\bots;

use pocketmine\command\Command;
use pocketmine\command\CommandSender;
use pocketmine\event\EventPriority;
use pocketmine\event\player\PlayerJoinEvent;
use pocketmine\event\player\PlayerPreLoginEvent;
use pocketmine\event\player\PlayerQuitEvent;
use pocketmine\network\mcpe\protocol\CameraInstructionPacket;
use pocketmine\network\mcpe\protocol\CameraPresetsPacket;
use pocketmine\network\mcpe\protocol\types\camera\CameraPreset;
use pocketmine\network\mcpe\protocol\types\camera\CameraSetInstruction;
use pocketmine\network\mcpe\protocol\types\camera\CameraSetInstructionEase;
use pocketmine\network\mcpe\protocol\types\camera\CameraSetInstructionEaseType;
use pocketmine\network\mcpe\protocol\types\camera\CameraSetInstructionRotation;
use pocketmine\permission\DefaultPermissionNames;
use pocketmine\permission\Permission;
use pocketmine\permission\PermissionManager;
use pocketmine\player\Player;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use function array_keys;
use function count;
use function implode;
use function is_string;
use function strtolower;

/**
 * Bots mark themselves with ClientData DeviceModel "riftal-devbot". Once
 * admitted they are ordinary Player objects, so every gameplay plugin already
 * treats them as players. The one thing done to them is a return to spawn on
 * join, so scenarios are repeatable; see onJoin().
 *
 * Admission needs both the riftal-dev-bots server option (the
 * --riftal-dev-bots=on flag or server.properties) and xbox-auth off. Bots
 * log in self-signed with no XUID, so a server that requires Xbox auth would
 * refuse them anyway, and this plugin refuses them first with a clear reason.
 *
 * /watch <bot> gives a real client a camera behind a bot's eyes. Bots render
 * nothing, so this is how a person sees what one sees. It exists only where
 * bots are admitted.
 *
 * This lives here until lib exists; riftal-game tracks moving it into
 * RiftalGames\Lib\Dev so plugins can ask whether a player is a dev bot
 * through lib rather than calling another plugin.
 */
final class Main extends PluginBase{

	public const BOT_DEVICE_MODEL = "riftal-devbot";
	private const WATCH_PERMISSION = "riftal.devbots.watch";
	// The camera is set every tick, so easing over one tick turns 20 jumps a
	// second into continuous motion.
	private const CAMERA_EASE_SECONDS = 0.05;

	private bool $admitting = false;

	/** @var array<string, true> lower-cased names of bots admitted but not yet joined */
	private array $pending = [];

	/**
	 * Lower-cased bot name => entity id of the player it is. The id matters:
	 * a bot reconnecting under the same name kicks its own stale session, and
	 * that session's quit must not unregister the new one.
	 *
	 * @var array<string, int>
	 */
	private array $bots = [];

	/** @var array<string, string> lower-cased viewer name => lower-cased bot name */
	private array $watching = [];

	protected function onEnable() : void{
		$server = $this->getServer();
		$requested = $server->getConfigGroup()->getConfigBool("riftal-dev-bots", false);
		$this->admitting = $requested && !$server->requiresAuthentication();

		if($requested && !$this->admitting){
			$this->getLogger()->warning("riftal-dev-bots is on but xbox-auth is too; dev bots will be refused");
		}
		$this->getLogger()->info("dev bots " . ($this->admitting ? "admitted" : "refused"));

		$manager = $server->getPluginManager();
		$manager->registerEvent(PlayerPreLoginEvent::class, $this->onPreLogin(...), EventPriority::LOWEST, $this);
		$manager->registerEvent(PlayerJoinEvent::class, $this->onJoin(...), EventPriority::MONITOR, $this);
		$manager->registerEvent(PlayerQuitEvent::class, $this->onQuit(...), EventPriority::MONITOR, $this);

		if($this->admitting){
			$this->registerWatch();
		}
	}

	private function onPreLogin(PlayerPreLoginEvent $event) : void{
		$info = $event->getPlayerInfo();
		$model = $info->getExtraData()["DeviceModel"] ?? null;
		if(!is_string($model) || $model !== self::BOT_DEVICE_MODEL){
			return;
		}
		if(!$this->admitting){
			$event->setKickFlag(PlayerPreLoginEvent::KICK_FLAG_PLUGIN, "dev bots are disabled on this server");
			return;
		}
		$this->pending[strtolower($info->getUsername())] = true;
	}

	/**
	 * A bot starts every session at the world spawn. A player's saved position
	 * carries over between sessions, which would make each scenario begin
	 * wherever the last one ended and drift further out every run. Inventory
	 * and everything else a player keeps still carries over.
	 */
	private function onJoin(PlayerJoinEvent $event) : void{
		$player = $event->getPlayer();
		$name = $player->getName();
		$key = strtolower($name);
		if(!isset($this->pending[$key])){
			return;
		}
		unset($this->pending[$key]);
		$this->bots[$key] = $player->getId();
		$player->teleport($player->getWorld()->getSafeSpawn());
		$this->getLogger()->info("devbot joined $name");
	}

	private function onQuit(PlayerQuitEvent $event) : void{
		$player = $event->getPlayer();
		$name = strtolower($player->getName());
		unset($this->watching[$name]);
		if(($this->bots[$name] ?? null) !== $player->getId()){
			return;
		}
		unset($this->bots[$name]);
		foreach($this->watching as $viewer => $bot){
			if($bot === $name){
				$this->stopWatching($viewer, "$bot left");
			}
		}
	}

	private function registerWatch() : void{
		$permissions = PermissionManager::getInstance();
		$permissions->addPermission(new Permission(self::WATCH_PERMISSION, "Watch through a dev bot's eyes"));
		$permissions->getPermission(DefaultPermissionNames::GROUP_USER)?->addChild(self::WATCH_PERMISSION, true);

		$command = new class("watch", "See what a dev bot sees; /watch alone returns your camera", "/watch [bot]") extends Command{
			/** @var \Closure(CommandSender, list<string>) : void */
			public \Closure $handler;

			public function execute(CommandSender $sender, string $commandLabel, array $args) : void{
				($this->handler)($sender, $args);
			}
		};
		$command->setPermission(self::WATCH_PERMISSION);
		$command->handler = $this->onWatchCommand(...);
		$this->getServer()->getCommandMap()->register("riftaldevbots", $command);

		$this->getScheduler()->scheduleRepeatingTask(new ClosureTask($this->moveCameras(...)), 1);
	}

	/**
	 * @param list<string> $args
	 */
	private function onWatchCommand(CommandSender $sender, array $args) : void{
		if(!$sender instanceof Player){
			$sender->sendMessage("Only a player in the world can watch.");
			return;
		}
		$viewer = strtolower($sender->getName());
		if(count($args) === 0){
			if(isset($this->watching[$viewer])){
				$this->stopWatching($viewer, "back to your own view");
			}else{
				$online = array_keys($this->bots);
				$sender->sendMessage(count($online) === 0 ? "No dev bots online." : "Dev bots online: " . implode(", ", $online));
			}
			return;
		}
		$bot = strtolower($args[0]);
		if(!isset($this->bots[$bot]) || $this->getServer()->getPlayerExact($bot) === null){
			$sender->sendMessage("No dev bot called $args[0] is online.");
			return;
		}
		// The client resolves a camera instruction's preset by its index in the
		// last preset list it was sent, and the core never sends one.
		$sender->getNetworkSession()->sendDataPacket(CameraPresetsPacket::create([self::freePreset()]));
		$this->watching[$viewer] = $bot;
		$sender->sendMessage("Watching $bot. /watch to return.");
	}

	private function stopWatching(string $viewer, string $reason) : void{
		unset($this->watching[$viewer]);
		$player = $this->getServer()->getPlayerExact($viewer);
		if($player === null){
			return;
		}
		$player->getNetworkSession()->sendDataPacket(CameraInstructionPacket::create(null, true, null, null, null, null, null, null, null));
		$player->sendMessage("Stopped watching: $reason.");
	}

	private function moveCameras() : void{
		foreach($this->watching as $viewer => $botName){
			$player = $this->getServer()->getPlayerExact($viewer);
			$bot = $this->getServer()->getPlayerExact($botName);
			if($player === null){
				unset($this->watching[$viewer]);
				continue;
			}
			if($bot === null){
				$this->stopWatching($viewer, "$botName is gone");
				continue;
			}
			$location = $bot->getLocation();
			$player->getNetworkSession()->sendDataPacket(CameraInstructionPacket::create(
				new CameraSetInstruction(
					preset: 0,
					ease: new CameraSetInstructionEase(CameraSetInstructionEaseType::LINEAR, self::CAMERA_EASE_SECONDS),
					cameraPosition: $bot->getEyePos(),
					rotation: new CameraSetInstructionRotation($location->getPitch(), $location->getYaw()),
					facingPosition: null,
					viewOffset: null,
					entityOffset: null,
					default: null,
					ignoreStartingValuesComponent: false
				),
				null, null, null, null, null, null, null, null
			));
		}
	}

	private static function freePreset() : CameraPreset{
		return new CameraPreset(
			name: "minecraft:free",
			parent: "",
			xPosition: null,
			yPosition: null,
			zPosition: null,
			pitch: null,
			yaw: null,
			rotationSpeed: null,
			snapToTarget: null,
			horizontalRotationLimit: null,
			verticalRotationLimit: null,
			continueTargeting: null,
			blockListeningRadius: null,
			viewOffset: null,
			entityOffset: null,
			radius: null,
			yawLimitMin: null,
			yawLimitMax: null,
			audioListenerType: null,
			playerEffects: null,
			aimAssist: null,
			controlScheme: null,
			applyInheritedStartingRotation: false,
			startingRotation: null
		);
	}
}
