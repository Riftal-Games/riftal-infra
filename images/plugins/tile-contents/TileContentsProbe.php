<?php

/**
 * @name TileContentsProbe
 * @main riftal\dev\tilecontents\Main
 * @version 0.0.1
 * @api 5.0.0
 * @depend RiftalDevBots
 * @description Self-test fixture for selftest.sh beside it. Never loaded by a stack.
 */

declare(strict_types=1);

namespace riftal\dev\tilecontents;

use pocketmine\block\tile\Container;
use pocketmine\block\tile\Furnace;
use pocketmine\block\VanillaBlocks;
use pocketmine\command\CommandSender;
use pocketmine\console\ConsoleCommandSender;
use pocketmine\data\bedrock\item\SavedItemStackData;
use pocketmine\item\Item;
use pocketmine\item\VanillaItems;
use pocketmine\lang\Language;
use pocketmine\lang\Translatable;
use pocketmine\nbt\tag\CompoundTag;
use pocketmine\permission\DefaultPermissions;
use pocketmine\permission\PermissibleBase;
use pocketmine\permission\PermissibleDelegateTrait;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\Server;
use riftal\dev\bots\ShulkerCommand;
use function class_exists;
use function implode;
use function str_replace;

/**
 * Holds what an operator player holds without being the console or a dev bot,
 * so every devbots- command must refuse it.
 */
final class OperatorSender implements CommandSender{
	use PermissibleDelegateTrait;

	public function __construct(private Server $server){
		$this->perm = new PermissibleBase([DefaultPermissions::ROOT_OPERATOR => true]);
	}

	public function getLanguage() : Language{
		return $this->server->getLanguage();
	}

	public function sendMessage(Translatable|string $message) : void{
		if($message instanceof Translatable){
			$message = $this->getLanguage()->translate($message);
		}
		$this->server->getLogger()->info("tile-probe operator heard: " . str_replace("\n", " ", $message));
	}

	public function getServer() : Server{
		return $this->server;
	}

	public function getName() : string{
		return "tile-probe-operator";
	}

	public function getScreenLineHeight() : int{
		return 20;
	}

	public function setScreenLineHeight(?int $height) : void{
	}
}

/**
 * Once the server ticks, places a furnace above spawn holding 5 raw iron in
 * slot 0 and 3 iron ingots in slot 2 with no fuel, so nothing smelts, then
 * asks devbots-tile for it, for the air above it, and for a chunk far from
 * spawn, as the console and as an operator. Then turns the level's autosave
 * off and on through devbots-autosave, asks devbots-shulker for a name no
 * dev bot holds, and reads the shulker box it would hand over.
 * selftest.sh reads the log.
 */
final class Main extends PluginBase{

	private const COMMAND = "devbots-tile";
	private const AUTOSAVE = "devbots-autosave";
	private const SHULKER = "devbots-shulker";
	private const FAR = 100000;

	protected function onEnable() : void{
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask($this->probe(...)), 1);
	}

	private function probe() : void{
		$server = $this->getServer();
		$logger = $this->getLogger();
		$level = $server->getWorldManager()->getDefaultWorld();
		$spawn = $level->getSpawnLocation()->floor();
		[$x, $y, $z] = [$spawn->getFloorX(), $spawn->getFloorY() + 5, $spawn->getFloorZ()];
		$level->setBlockAt($x, $y, $z, VanillaBlocks::FURNACE());
		$furnace = $level->getTileAt($x, $y, $z);
		if($furnace instanceof Furnace){
			$furnace->getInventory()->setItem(0, VanillaItems::RAW_IRON()->setCount(5));
			$furnace->getInventory()->setItem(2, VanillaItems::IRON_INGOT()->setCount(3));
		}
		$name = $level->getFolderName();
		$registered = [];
		foreach([self::COMMAND, self::AUTOSAVE, self::SHULKER] as $command){
			$registered[] = $server->getCommandMap()->getCommand($command) !== null ? "yes" : "no";
		}
		$logger->info("tile-probe at $name $x $y $z registered=" . implode(",", $registered));

		$console = new ConsoleCommandSender($server, $server->getLanguage());
		$air = $y + 1;
		$far = self::FAR;
		foreach(["$x $y $z", "$x $y $z $name", "$x $air $z", "$far 70 $far"] as $args){
			$server->dispatchCommand($console, self::COMMAND . " $args");
		}
		$server->dispatchCommand(new OperatorSender($server), self::COMMAND . " $x $y $z");

		// Read past devbots-tile, straight from the inventory, so a command that
		// writes while printing what it found still shows up as a changed furnace.
		$after = [];
		$tile = $level->getTileAt($x, $y, $z);
		if($tile instanceof Furnace){
			foreach($tile->getInventory()->getContents(true) as $slot => $item){
				$after[] = "$slot=" . ($item->isNull() ? "empty" : $item->getVanillaName() . " x" . $item->getCount());
			}
		}
		$logger->info("tile-probe after " . implode(", ", $after));

		$operator = new OperatorSender($server);
		$server->dispatchCommand($console, self::AUTOSAVE . " off");
		$off = $level->getAutoSave();
		$server->dispatchCommand($operator, self::AUTOSAVE . " on $name");
		$operatorOn = $level->getAutoSave();
		$server->dispatchCommand($console, self::AUTOSAVE . " on $name");
		$server->dispatchCommand($console, self::AUTOSAVE . " off nowhere");
		$logger->info("tile-probe autosave off=" . self::flag($off) . " operator=" . self::flag($operatorOn) . " on=" . self::flag($level->getAutoSave()));

		$server->dispatchCommand($console, self::SHULKER . " nobody");
		$server->dispatchCommand($operator, self::SHULKER . " nobody");
		if(!class_exists(ShulkerCommand::class)){
			$logger->info("tile-probe shulker no " . ShulkerCommand::class);
			$server->shutdown();
			return;
		}
		$shulker = ShulkerCommand::filled();
		$inside = [];
		foreach($shulker->getNamedTag()->getListTag(Container::TAG_ITEMS, CompoundTag::class) ?? [] as $stack){
			$item = Item::nbtDeserialize($stack);
			$inside[] = $stack->getByte(SavedItemStackData::TAG_SLOT) . "=" . $item->getVanillaName() . " x" . $item->getCount();
		}
		$logger->info("tile-probe shulker " . $shulker->getVanillaName() . " x" . $shulker->getCount() . " holds " . implode(", ", $inside));
		$server->shutdown();
	}

	private static function flag(bool $on) : string{
		return $on ? "on" : "off";
	}
}
