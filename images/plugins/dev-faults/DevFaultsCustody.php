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

use pocketmine\console\ConsoleCommandSender;
use pocketmine\nbt\tag\CompoundTag;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\utils\Filesystem;
use RiftalGames\Contracts\Chunk\DurableChunkSaveEvent;
use Symfony\Component\Filesystem\Path;
use function class_exists;
use function getenv;
use function implode;
use function is_dir;
use function sprintf;
use function unlink;

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
		foreach(["devfaults-flush-fail", "devfaults-probe-fail", "devfaults-chunk-save-fail"] as $command){
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

	private function probePath() : string{
		return Path::join($this->getServer()->getDataPath(), "players", ".custody-probe");
	}
}
