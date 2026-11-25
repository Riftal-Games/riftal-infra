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
 * Holds one permission and nothing else, without being the console. Built
 * standalone because a ConsoleCommandSender subclass would pass the
 * console-only check by its type alone.
 */
final class ProbeSender implements CommandSender{
	use PermissibleDelegateTrait;

	public function __construct(private Server $server, private string $role, string $permission){
		$this->perm = new PermissibleBase([$permission => true]);
	}

	public function getLanguage() : Language{
		return $this->server->getLanguage();
	}

	public function sendMessage(Translatable|string $message) : void{
		if($message instanceof Translatable){
			$message = $this->getLanguage()->translate($message);
		}
		$this->server->getLogger()->info("crash-hook-probe $this->role heard: " . str_replace("\n", " ", $message));
	}

	public function getServer() : Server{
		return $this->server;
	}

	public function getName() : string{
		return "crash-hook-probe-" . $this->role;
	}

	public function getScreenLineHeight() : int{
		return 20;
	}

	public function setScreenLineHeight(?int $height) : void{
	}
}

/**
 * Once the server ticks, reports whether devbots-crash exists, runs it as an
 * operator, as a holder of the console permission that is not the console,
 * then as the console, and shuts down if the process is still alive.
 * selftest.sh reads the result from the log.
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

		$server->dispatchCommand(new ProbeSender($server, "operator", DefaultPermissions::ROOT_OPERATOR), self::COMMAND);
		$logger->info("crash-hook-probe alive after operator");

		$server->dispatchCommand(new ProbeSender($server, "holder", DefaultPermissions::ROOT_CONSOLE), self::COMMAND);
		$logger->info("crash-hook-probe alive after holder");

		$server->dispatchCommand(new ConsoleCommandSender($server, $server->getLanguage()), self::COMMAND);
		$logger->info("crash-hook-probe alive after console");
		$server->shutdown();
	}
}
