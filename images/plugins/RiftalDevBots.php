<?php

/**
 * @name RiftalDevBots
 * @main riftal\dev\bots\Main
 * @version 0.4.0
 * @api 5.0.0
 * @softdepend RiftalCustody
 * @description Dev stack only. Admits the headless player bots from devtools/bot.
 */

// The softdepend keeps RiftalCustody enabled until this plugin has disabled, so
// its shutdown sweep runs after anything this plugin drops (ADR 013, item 2).

declare(strict_types=1);

namespace riftal\dev\bots;

use Closure;
use Logger;
use pocketmine\block\tile\Container;
use pocketmine\block\VanillaBlocks;
use pocketmine\command\Command;
use pocketmine\command\CommandSender;
use pocketmine\command\utils\InvalidCommandSyntaxException;
use pocketmine\console\ConsoleCommandSender;
use pocketmine\data\bedrock\item\ItemTypeSerializeException;
use pocketmine\event\entity\EntityTeleportEvent;
use pocketmine\event\EventPriority;
use pocketmine\event\player\PlayerJoinEvent;
use pocketmine\event\player\PlayerLoginEvent;
use pocketmine\event\player\PlayerPreLoginEvent;
use pocketmine\event\player\PlayerQuitEvent;
use pocketmine\item\Item;
use pocketmine\item\VanillaItems;
use pocketmine\nbt\NBT;
use pocketmine\nbt\tag\ListTag;
use pocketmine\permission\DefaultPermissions;
use pocketmine\player\Player;
use pocketmine\plugin\PluginBase;
use pocketmine\utils\Process;
use pocketmine\world\format\Chunk;
use pocketmine\world\format\io\GlobalItemDataHandlers;
use pocketmine\world\World;
use function count;
use function is_string;
use function preg_match;
use function strrchr;
use function strtolower;
use function substr;

/**
 * Pure admission logic, kept free of every PocketMine type so it stays
 * checkable without a running server (riftal-infra#113's selftest.sh does
 * exactly that against this real file).
 *
 * `requiresAuthentication()` alone stopped being a structural gate the day
 * WaterdogPE ships: every downstream behind the proxy runs xbox-auth=false
 * (CLAUDE.md hard rule 6), so a production instance would satisfy it too,
 * leaving only "the flag was never set" between a dev stack and a live one.
 * The environment variable is the second, independent signal: it is not a
 * PocketMine config value, nothing in server.properties or a --flag can set
 * it, and no production deploy path has a reason to ever export it.
 */
final class DevEnvGate{

	public const ENV_VAR = "RIFTAL_DEV_ENV";

	public static function isDevEnvironment(?string $envValue) : bool{
		return $envValue === "1";
	}

	public static function shouldAdmit(bool $flagRequested, bool $requiresAuth, ?string $envValue) : bool{
		return $flagRequested && !$requiresAuth && self::isDevEnvironment($envValue);
	}
}

/**
 * Bots mark themselves with ClientData DeviceModel "riftal-devbot". Once
 * admitted they are ordinary Player objects, so every gameplay plugin already
 * treats them as players. The one thing done to them is a return to spawn on
 * join, so scenarios are repeatable. A plugin placing players on login or
 * on join overrides that return; see onTeleport() and onJoin().
 *
 * Admission needs the riftal-dev-bots server option (the --riftal-dev-bots=on
 * flag or server.properties), xbox-auth off, and RIFTAL_DEV_ENV=1; see
 * DevEnvGate above for why the third signal exists. Bots log in self-signed
 * with no XUID, so a server that requires Xbox auth would refuse them
 * anyway, and this plugin refuses them first with a clear reason.
 *
 * This lives here until lib exists; riftal-game tracks moving it into
 * RiftalGames\Lib\Dev so plugins can ask whether a player is a dev bot
 * through lib rather than calling another plugin.
 */
final class Main extends PluginBase{

	public const BOT_DEVICE_MODEL = "riftal-devbot";

	private bool $admitting = false;

	/**
	 * Lower-cased names of bots admitted but not yet joined => the entity id
	 * of the session admitted, null until it logs in, and whether a plugin
	 * has teleported that session since. The id matters: a bot reconnecting
	 * under the same name keeps its stale session online until core kicks it
	 * as a duplicate, after the new pre-login, and nothing done to the stale
	 * session may count for the new one.
	 *
	 * @var array<string, array{session: ?int, placed: bool}>
	 */
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
		$envValue = getenv(DevEnvGate::ENV_VAR);
		$this->admitting = DevEnvGate::shouldAdmit(
			$requested,
			$server->requiresAuthentication(),
			$envValue === false ? null : $envValue
		);

		if($requested && !$this->admitting){
			$this->getLogger()->warning(
				"riftal-dev-bots is on but xbox-auth is on or " . DevEnvGate::ENV_VAR
				. "=1 is not set; dev bots will be refused"
			);
		}
		$this->getLogger()->info("dev bots " . ($this->admitting ? "admitted" : "refused"));

		$manager = $server->getPluginManager();
		$manager->registerEvent(PlayerPreLoginEvent::class, $this->onPreLogin(...), EventPriority::LOWEST, $this);
		$manager->registerEvent(PlayerLoginEvent::class, $this->onLogin(...), EventPriority::LOWEST, $this);
		$manager->registerEvent(EntityTeleportEvent::class, $this->onTeleport(...), EventPriority::MONITOR, $this);
		$manager->registerEvent(PlayerJoinEvent::class, $this->onJoin(...), EventPriority::LOWEST, $this);
		$manager->registerEvent(PlayerQuitEvent::class, $this->onQuit(...), EventPriority::MONITOR, $this);

		if($this->admitting){
			$server->getCommandMap()->registerAll("riftaldevbots", [
				new CrashCommand($this->getLogger()),
				new TileCommand($this->getLogger(), $this->isBot(...)),
				new AutosaveCommand($this->getLogger(), $this->isBot(...)),
				new ShulkerCommand($this->getLogger(), $this->isBot(...)),
			]);
		}
	}

	private function isBot(Player $player) : bool{
		return ($this->bots[strtolower($player->getName())] ?? null) === $player->getId();
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
		$this->pending[strtolower($info->getUsername())] = ["session" => null, "placed" => false];
	}

	/**
	 * Core kicks a stale same-name session before it creates the new one's
	 * player, and fires PlayerLoginEvent as soon as it has, so the last bot
	 * session to log in under a pending name is the admitted one. Registered
	 * at LOWEST so it binds before any login placer at a later priority, and
	 * it drops anything a stale session's teleports recorded.
	 *
	 * Same-name sessions win in the order their login checks finish on the
	 * async pool, not the order they pre-logged in, so the pending entry says
	 * only that some bot pre-logged in under the name. The session logging in
	 * is bound only when its own login carries the bot device model.
	 */
	private function onLogin(PlayerLoginEvent $event) : void{
		$player = $event->getPlayer();
		$key = strtolower($player->getName());
		if(!isset($this->pending[$key])){
			return;
		}
		$device = $player->getPlayerInfo()->getExtraData()["DeviceModel"] ?? null;
		if($device !== self::BOT_DEVICE_MODEL){
			unset($this->pending[$key]);
			return;
		}
		$this->pending[$key] = ["session" => $player->getId(), "placed" => false];
	}

	/**
	 * A teleport of the admitted session between its login and its join is a
	 * plugin placing the bot, such as the login-spawn teleport riftal-game#222
	 * gives ranks on PlayerLoginEvent, and it stands. A teleport of any other
	 * entity under the same name, such as a mine reset moving a stale session,
	 * does not count.
	 * MONITOR sees only teleports no listener cancelled.
	 */
	private function onTeleport(EntityTeleportEvent $event) : void{
		$entity = $event->getEntity();
		if(!$entity instanceof Player){
			return;
		}
		$key = strtolower($entity->getName());
		if(($this->pending[$key]["session"] ?? null) === $entity->getId()){
			$this->pending[$key]["placed"] = true;
		}
	}

	/**
	 * A bot starts every session at its current world's safe spawn, unless a
	 * plugin placed it first. A player's saved position carries over between
	 * sessions, which would make each scenario begin wherever the last one
	 * ended and drift further out every run. Inventory and everything else a
	 * player keeps still carries over.
	 *
	 * Registered at LOWEST so it runs first: any plugin placing players on join
	 * at any priority after LOWEST, such as RiftalMines' join_teleport, has the
	 * last word, and the bot lands where a real player would.
	 * join-order/selftest.sh holds this order and the teleport watch.
	 */
	private function onJoin(PlayerJoinEvent $event) : void{
		$player = $event->getPlayer();
		$name = $player->getName();
		$key = strtolower($name);
		if(($this->pending[$key]["session"] ?? null) !== $player->getId()){
			return;
		}
		$placed = $this->pending[$key]["placed"];
		unset($this->pending[$key]);
		$this->bots[$key] = $player->getId();
		if(!$placed){
			$player->teleport($player->getWorld()->getSafeSpawn());
		}
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

/**
 * ADR 017's crash proofs need the server to die mid-tick with no save, no
 * shutdown and no plugin disable, as a host crash or an OOM kill would. The
 * guard refuses killing a server container from outside, so the process kills
 * itself. SIGKILL cannot be caught, so nothing in the process runs after it.
 *
 * Registered only when Main admits dev bots, so a server without
 * --riftal-dev-bots=on, xbox-auth off and RIFTAL_DEV_ENV=1 has no such
 * command. Runnable only from the server console: a player who could run it
 * could throw away every unsaved change on the instance at will.
 * crash-hook/selftest.sh holds both.
 */
final class CrashCommand extends Command{

	public const NAME = "devbots-crash";

	public function __construct(private Logger $logger){
		parent::__construct(self::NAME, "Dev stack only. Kills this server process with SIGKILL, for crash proofs.");
		$this->setPermission(DefaultPermissions::ROOT_CONSOLE);
	}

	public function execute(CommandSender $sender, string $commandLabel, array $args) : bool{
		if(!$sender instanceof ConsoleCommandSender){
			$sender->sendMessage(self::NAME . " runs only from the server console");
			return true;
		}
		$pid = Process::pid();
		// The kernel drops a SIGKILL sent to a PID namespace's init from inside
		// that namespace, so the server would carry on as if nothing happened.
		// A crash proof run on it would measure a run with no crash in it.
		if($pid === 1){
			$this->logger->error(self::NAME . ": refused, this server is process 1 in its container, and a process 1 cannot SIGKILL itself; run the image with an init such as tini as process 1");
			return true;
		}
		$this->logger->warning(self::NAME . ": killing process $pid with SIGKILL");
		Process::kill($pid);
		return true;
	}
}

/**
 * ADR 025 P5 and spec 020's M3 criteria compare a tile's server-side contents
 * with a bot's client view, slot by slot. Every line goes to the server log,
 * each named by its level and position, and the first of a read carries the
 * server tick. It only reads: a chunk nothing holds loaded is reported, never
 * loaded, so asking cannot change what a scenario measures.
 *
 * Registered only when Main admits dev bots. The console and an admitted dev
 * bot may run it, and the bot also gets the lines in chat; nobody else can.
 * tile-contents/selftest.sh holds the gate and the output.
 */
final class TileCommand extends Command{

	public const NAME = "devbots-tile";

	/** @param Closure(Player) : bool $isBot */
	public function __construct(private Logger $logger, private Closure $isBot){
		parent::__construct(self::NAME, "Dev stack only. Logs a tile's server-side contents slot by slot.", "/" . self::NAME . " <x> <y> <z> [level]");
		$this->setPermission(DefaultPermissions::ROOT_USER);
	}

	public function execute(CommandSender $sender, string $commandLabel, array $args) : bool{
		$console = $sender instanceof ConsoleCommandSender;
		if(!$console && !($sender instanceof Player && ($this->isBot)($sender))){
			$sender->sendMessage(self::NAME . " runs only from the server console or a dev bot");
			return true;
		}
		if(count($args) < 3 || count($args) > 4){
			throw new InvalidCommandSyntaxException();
		}
		foreach([$args[0], $args[1], $args[2]] as $coordinate){
			if(preg_match('/^-?\d{1,9}$/', $coordinate) !== 1){
				throw new InvalidCommandSyntaxException();
			}
		}
		$server = $sender->getServer();
		$level = match(true){
			isset($args[3]) => $server->getWorldManager()->getWorldByName($args[3]),
			$sender instanceof Player => $sender->getWorld(),
			default => $server->getWorldManager()->getDefaultWorld(),
		};
		$lines = $level === null
			? [self::NAME . " " . ($args[3] ?? "default") . " is not a loaded level"]
			: self::describe($level, (int) $args[0], (int) $args[1], (int) $args[2], $server->getTick());
		foreach($lines as $line){
			$this->logger->info($line);
			if(!$console){
				$sender->sendMessage($line);
			}
		}
		return true;
	}

	/** @return list<string> */
	private static function describe(World $level, int $x, int $y, int $z, int $tick) : array{
		$at = self::NAME . " " . $level->getFolderName() . " $x $y $z";
		if(!$level->isChunkLoaded($x >> Chunk::COORD_BIT_SIZE, $z >> Chunk::COORD_BIT_SIZE)){
			return ["$at tick=$tick chunk not loaded"];
		}
		$tile = $level->getTileAt($x, $y, $z);
		if($tile === null){
			return ["$at tick=$tick no tile"];
		}
		$class = substr((string) strrchr("\\" . $tile::class, "\\"), 1);
		if(!$tile instanceof Container){
			return ["$at tick=$tick tile=$class holds no inventory"];
		}
		$inventory = $tile->getRealInventory();
		$size = $inventory->getSize();
		$lines = ["$at tick=$tick tile=$class slots=$size"];
		for($slot = 0; $slot < $size; ++$slot){
			$lines[] = "$at slot=$slot " . self::stack($inventory->getItem($slot));
		}
		return $lines;
	}

	/**
	 * Bedrock's own id and meta, the names a client's item table uses, so a
	 * bot can compare a slot with its own view of it.
	 */
	private static function stack(Item $item) : string{
		if($item->isNull()){
			return "empty";
		}
		try{
			$data = GlobalItemDataHandlers::getSerializer()->serializeType($item);
			$type = "id=" . $data->getName() . " meta=" . $data->getMeta();
		}catch(ItemTypeSerializeException){
			$type = "id=? name=" . $item->getVanillaName();
		}
		return "$type count=" . $item->getCount() . " nbt=" . ($item->hasNamedTag() ? "yes" : "no");
	}
}

/**
 * Spec 020 criterion 22 needs one level's autosave off, as save-off or ADR
 * 015's hold sets it, while a bot tries a furnace. An admitted bot is no
 * operator and cannot run save-off, which also turns off every level at once.
 *
 * Registered only when Main admits dev bots. The console and an admitted dev
 * bot may run it; nobody else can. tile-contents/selftest.sh holds the gate.
 */
final class AutosaveCommand extends Command{

	public const NAME = "devbots-autosave";

	/** @param Closure(Player) : bool $isBot */
	public function __construct(private Logger $logger, private Closure $isBot){
		parent::__construct(self::NAME, "Dev stack only. Turns one level's autosave on or off.", "/" . self::NAME . " <on|off> [level]");
		$this->setPermission(DefaultPermissions::ROOT_USER);
	}

	public function execute(CommandSender $sender, string $commandLabel, array $args) : bool{
		$console = $sender instanceof ConsoleCommandSender;
		if(!$console && !($sender instanceof Player && ($this->isBot)($sender))){
			$sender->sendMessage(self::NAME . " runs only from the server console or a dev bot");
			return true;
		}
		if(count($args) < 1 || count($args) > 2 || ($args[0] !== "on" && $args[0] !== "off")){
			throw new InvalidCommandSyntaxException();
		}
		$server = $sender->getServer();
		$level = match(true){
			isset($args[1]) => $server->getWorldManager()->getWorldByName($args[1]),
			$sender instanceof Player => $sender->getWorld(),
			default => $server->getWorldManager()->getDefaultWorld(),
		};
		if($level === null){
			$line = self::NAME . " " . $args[1] . " is not a loaded level";
		}else{
			$level->setAutoSave($args[0] === "on");
			$line = self::NAME . " " . $level->getFolderName() . " tick=" . $server->getTick() . " autosave=" . ($level->getAutoSave() ? "on" : "off");
		}
		$this->logger->info($line);
		if(!$console){
			$sender->sendMessage($line);
		}
		return true;
	}
}

/**
 * Spec 020 criterion 24 needs a bot holding a filled shulker box, which no M3
 * player can fill. This hands one over, so it is the one place on any stack
 * where the server makes an item, against hard rule 1; that is why it exists
 * only while Main admits dev bots and gives only to an admitted dev bot.
 *
 * The console and an admitted dev bot may run it; nobody else can.
 * tile-contents/selftest.sh holds the gate and the item.
 */
final class ShulkerCommand extends Command{

	public const NAME = "devbots-shulker";

	/** @param Closure(Player) : bool $isBot */
	public function __construct(private Logger $logger, private Closure $isBot){
		parent::__construct(self::NAME, "Dev stack only. Hands an admitted dev bot a filled shulker box.", "/" . self::NAME . " <bot>");
		$this->setPermission(DefaultPermissions::ROOT_USER);
	}

	/**
	 * Holds its stack the way core's own shulker box drop does: the tile's
	 * Items list at the root of the item's tag (block/ShulkerBox.php).
	 */
	public static function filled() : Item{
		$item = VanillaBlocks::SHULKER_BOX()->asItem();
		$tag = $item->getNamedTag();
		$tag->setTag(Container::TAG_ITEMS, new ListTag([VanillaItems::STICK()->nbtSerialize(0)], NBT::TAG_Compound));
		return $item->setNamedTag($tag);
	}

	public function execute(CommandSender $sender, string $commandLabel, array $args) : bool{
		$console = $sender instanceof ConsoleCommandSender;
		if(!$console && !($sender instanceof Player && ($this->isBot)($sender))){
			$sender->sendMessage(self::NAME . " runs only from the server console or a dev bot");
			return true;
		}
		if(count($args) !== 1){
			throw new InvalidCommandSyntaxException();
		}
		$bot = $sender->getServer()->getPlayerExact($args[0]);
		$item = self::filled();
		$line = match(true){
			$bot === null || !($this->isBot)($bot) => self::NAME . " " . $args[0] . " is not an admitted dev bot",
			!$bot->getInventory()->canAddItem($item) => self::NAME . " " . $bot->getName() . " has no room",
			default => self::NAME . " " . $bot->getName() . " handed " . (count($bot->getInventory()->addItem($item)) === 0 ? "a filled shulker box" : "nothing"),
		};
		$this->logger->info($line);
		if(!$console){
			$sender->sendMessage($line);
		}
		return true;
	}
}
