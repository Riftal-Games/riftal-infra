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
use Symfony\Component\Filesystem\Path;
use function getenv;
use function is_dir;
use function sprintf;
use function unlink;

/**
 * Named RiftalCustody, so RiftalDevFaults' softdepend applies to it, and
 * enabled at STARTUP as custody is. Records whether the probe path is a
 * directory when it enables, which is when custody runs its boot probe, then
 * drives both faults the way a P8 scenario would and reports what core did.
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
		$registered = $server->getCommandMap()->getCommand("devfaults-flush-fail") !== null;
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
			"dev-faults-probe dir_at_enable=%s commands=%s failing=%s other=%s probe=%s",
			$this->probeDirAtEnable ? "yes" : "no",
			$registered ? "yes" : "no",
			$server->hasOfflinePlayerData($failing) ? "saved" : "unsaved",
			$server->hasOfflinePlayerData($other) ? "saved" : "unsaved",
			$probe
		));
		$server->shutdown();
	}

	private function probePath() : string{
		return Path::join($this->getServer()->getDataPath(), "players", ".custody-probe");
	}
}
