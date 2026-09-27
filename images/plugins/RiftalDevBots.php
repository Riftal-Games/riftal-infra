<?php

/**
 * @name RiftalDevBots
 * @main riftal\dev\bots\Main
 * @version 0.2.0
 * @api 5.0.0
 * @description Dev stack only. Admits the headless player bots from devtools/bot.
 */

declare(strict_types=1);

namespace riftal\dev\bots;

use pocketmine\event\EventPriority;
use pocketmine\event\player\PlayerJoinEvent;
use pocketmine\event\player\PlayerPreLoginEvent;
use pocketmine\event\player\PlayerQuitEvent;
use pocketmine\plugin\PluginBase;
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
 * This lives here until lib exists; riftal-game tracks moving it into
 * RiftalGames\Lib\Dev so plugins can ask whether a player is a dev bot
 * through lib rather than calling another plugin.
 */
final class Main extends PluginBase{

	public const BOT_DEVICE_MODEL = "riftal-devbot";

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
		if(($this->bots[$name] ?? null) !== $player->getId()){
			return;
		}
		unset($this->bots[$name]);
	}
}
