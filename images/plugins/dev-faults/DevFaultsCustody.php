<?php

/**
 * @name RiftalCustody
 * @main riftal\dev\faultsprobe\Main
 * @version 0.0.1
 * @api 5.0.0
 * @load STARTUP
 * @description Self-test fixture for selftest.sh beside it, standing in for riftal-game's custody. Never loaded by a stack.
 */

declare(strict_types=1);

namespace riftal\dev\faultsprobe;

use pocketmine\command\CommandSender;
use pocketmine\console\ConsoleCommandSender;
use pocketmine\event\EventPriority;
use pocketmine\lang\Language;
use pocketmine\lang\Translatable;
use pocketmine\nbt\tag\CompoundTag;
use pocketmine\permission\DefaultPermissions;
use pocketmine\permission\PermissibleBase;
use pocketmine\permission\PermissibleDelegateTrait;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\Server;
use pocketmine\utils\Filesystem;
use RiftalGames\Contracts\Chunk\DurableChunkSaveEvent;
use RiftalGames\Contracts\Economy\CurrencyDebitRequestedEvent;
use RiftalGames\Contracts\QueryFailure;
use Symfony\Component\Filesystem\Path;
use function class_exists;
use function count;
use function getenv;
use function implode;
use function in_array;
use function is_dir;
use function sprintf;
use function trim;
use function unlink;
use const PHP_INT_MAX;

/**
 * Named RiftalCustody, so RiftalDevFaults' softdepend applies to it, and
 * enabled at STARTUP as custody is. Records whether the probe path is a
 * directory when it enables, which is when custody runs its boot probe, then
 * drives every fault the way a P8 or ADR 030 scenario would and reports what
 * core did.
 */
final class Main extends PluginBase{

	private bool $probeDirAtEnable = false;

	protected function onEnable() : void{
		$this->probeDirAtEnable = is_dir($this->probePath());
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask($this->probe(...)), 1);
	}

	private function probe() : void{
		$server = $this->getServer();
		$console = new ConsoleCommandSender($server, $server->getLanguage());
		$boot = (string) getenv("FAULTS_BOOT");
		$failing = "failing$boot";
		$other = "other$boot";
		$map = $server->getCommandMap();
		$byName = [];
		foreach(["devfaults-flush-fail", "devfaults-probe-fail", "devfaults-chunk-save-fail", "devfaults-debit"] as $command){
			$byName[] = $command . "=" . ($map->getCommand($command) !== null ? "yes" : "no");
		}
		$this->getLogger()->info("dev-faults-commands " . implode(" ", $byName));
		$registered = $map->getCommand("devfaults-flush-fail") !== null;
		if($registered){
			$server->dispatchCommand($console, "devfaults-flush-fail $failing");
			if(getenv("FAULTS_ARM_PROBE") === "1"){
				$server->dispatchCommand($console, "devfaults-probe-fail");
			}
		}
		$server->saveOfflinePlayerData($failing, CompoundTag::create()->setString("probe", $boot));
		$server->saveOfflinePlayerData($other, CompoundTag::create()->setString("probe", $boot));

		try{
			Filesystem::safeFilePutContents($this->probePath(), "probe");
			unlink($this->probePath());
			$probe = "writes";
		}catch(\RuntimeException){
			$probe = "throws";
		}
		$this->debitChecks($console);
		$this->getLogger()->info(sprintf(
			"dev-faults-probe dir_at_enable=%s commands=%s failing=%s other=%s probe=%s chunk=%s",
			$this->probeDirAtEnable ? "yes" : "no",
			$registered ? "yes" : "no",
			$server->hasOfflinePlayerData($failing) ? "saved" : "unsaved",
			$server->hasOfflinePlayerData($other) ? "saved" : "unsaved",
			$probe,
			$this->chunkSaves($console)
		));
		$server->shutdown();
	}

	/**
	 * Fires the event as lib's DurableChunkSave does, whether or not the gate
	 * is open, so a boot with the gate shut shows that nothing cancels it.
	 * Arms chunk 0 0, then saves chunk 1 0 and chunk 0 0 twice: only the first
	 * save of 0 0 may come back cancelled.
	 */
	private function chunkSaves(ConsoleCommandSender $console) : string{
		if(!class_exists(DurableChunkSaveEvent::class)){
			return "absent";
		}
		$server = $this->getServer();
		$level = $server->getWorldManager()->getDefaultWorld();
		if($level === null){
			return "nolevel";
		}
		if($server->getCommandMap()->getCommand("devfaults-chunk-save-fail") !== null){
			$server->dispatchCommand($console, "devfaults-chunk-save-fail nosuchlevel 0 0");
			$server->dispatchCommand($console, "devfaults-chunk-save-fail " . $level->getFolderName() . " 0 0");
		}
		$results = [];
		foreach([[1, 0], [0, 0], [0, 0]] as [$x, $z]){
			$event = new DurableChunkSaveEvent($level, $x, $z);
			$event->call();
			$results[] = $event->isCancelled() ? "cancelled" : "saved";
		}
		return implode(",", $results);
	}

	/**
	 * Stands in for economy: a listener that answers the four outcomes in turn.
	 * Lines that must fire nothing run first, a sender that is not the console
	 * among them, then four valid debits. The count of events the listener has
	 * seen is what shows a refused line fired nothing.
	 */
	private function debitChecks(ConsoleCommandSender $console) : void{
		$server = $this->getServer();
		if($server->getCommandMap()->getCommand("devfaults-debit") === null){
			return;
		}
		$reasons = [];
		$server->getPluginManager()->registerEvent(CurrencyDebitRequestedEvent::class, static function(CurrencyDebitRequestedEvent $event) use (&$reasons) : void{
			$reasons[] = $event->reason()->value;
			match(count($reasons)){
				1 => $event->debited(),
				2 => $event->rejected(),
				3 => $event->notApplied(),
				default => $event->failed(new QueryFailure("stub"))
			};
		}, EventPriority::NORMAL, $this);

		foreach(["", "7", "7 250 1", "0 250", "7 0", "-1 250", "7 -5", "abc 250", "7 1.5", "7 0x10", "7 +5", "7 99999999999999999999"] as $args){
			$server->dispatchCommand($console, trim("devfaults-debit $args"));
		}
		$notConsole = new class($server) implements CommandSender{
			use PermissibleDelegateTrait;

			/** @var list<string> */
			public array $messages = [];

			public function __construct(private Server $server){
				$this->perm = new PermissibleBase([DefaultPermissions::ROOT_CONSOLE => true]);
			}

			public function getLanguage() : Language{
				return $this->server->getLanguage();
			}

			public function sendMessage(Translatable|string $message) : void{
				$this->messages[] = $message instanceof Translatable ? $message->getText() : $message;
			}

			public function getServer() : Server{
				return $this->server;
			}

			public function getName() : string{
				return "notconsole";
			}

			public function getScreenLineHeight() : int{
				return PHP_INT_MAX;
			}

			public function setScreenLineHeight(?int $height) : void{
			}
		};
		$server->dispatchCommand($notConsole, "devfaults-debit 7 250");
		$refusedFired = count($reasons);
		$refusedSays = in_array("devfaults-debit runs only from the server console", $notConsole->messages, true) ? "yes" : "no";

		for($i = 0; $i < 4; $i++){
			$server->dispatchCommand($console, "devfaults-debit 7 250");
		}
		$this->getLogger()->info(sprintf(
			"dev-faults-debit refused_fired=%d refused_says=%s events=%d reasons=%s",
			$refusedFired,
			$refusedSays,
			count($reasons),
			implode(",", $reasons)
		));
	}

	private function probePath() : string{
		return Path::join($this->getServer()->getDataPath(), "players", ".custody-probe");
	}
}
