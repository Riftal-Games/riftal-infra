<?php

/**
 * @name CrashHookProbe
 * @main riftal\dev\crashhook\Main
 * @version 0.0.1
 * @api 5.0.0
 * @depend RiftalDevBots
 * @description Self-test fixture for selftest.sh beside it. Never loaded by a stack.
 */

declare(strict_types=1);

namespace riftal\dev\crashhook;

use pocketmine\command\CommandSender;
use pocketmine\console\ConsoleCommandSender;
use pocketmine\lang\Language;
use pocketmine\lang\Translatable;
use pocketmine\permission\DefaultPermissions;
use pocketmine\permission\PermissibleBase;
use pocketmine\permission\PermissibleDelegateTrait;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\Server;
use function str_replace;

/**
 * Holds what an operator player holds, without being the console. Built
 * standalone because a ConsoleCommandSender subclass would pass the
 * console-only check by its type alone.
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
		$this->server->getLogger()->info("crash-hook-probe operator heard: " . str_replace("\n", " ", $message));
	}

	public function getServer() : Server{
		return $this->server;
	}

	public function getName() : string{
		return "crash-hook-probe-operator";
	}

	public function getScreenLineHeight() : int{
		return 20;
	}

	public function setScreenLineHeight(?int $height) : void{
	}
}

/**
 * Once the server ticks, reports whether devbots-crash exists, runs it as an
 * operator, then as the console, and shuts down if the process is still
 * alive. selftest.sh reads the result from the log.
 */
final class Main extends PluginBase{

	private const COMMAND = "devbots-crash";

	protected function onEnable() : void{
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask($this->probe(...)), 1);
	}

	private function probe() : void{
		$server = $this->getServer();
		$logger = $this->getLogger();
		$registered = $server->getCommandMap()->getCommand(self::COMMAND) !== null;
		$logger->info("crash-hook-probe registered=" . ($registered ? "yes" : "no"));

		$server->dispatchCommand(new OperatorSender($server), self::COMMAND);
		$logger->info("crash-hook-probe alive after operator");

		$server->dispatchCommand(new ConsoleCommandSender($server, $server->getLanguage()), self::COMMAND);
		$logger->info("crash-hook-probe alive after console");
		$server->shutdown();
	}
}
