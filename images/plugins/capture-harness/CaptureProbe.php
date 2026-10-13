<?php

/**
 * @name CaptureProbe
 * @main riftal\captureprobe\Main
 * @version 0.1.0
 * @api 5.0.0
 * @description Loaded only by capture-harness/harness.sh: logs the server's autosave flag whenever it changes.
 */

declare(strict_types=1);

namespace riftal\captureprobe;

use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;

/**
 * RiftalCapture's release line reports the value it meant to set. This reads
 * the flag itself, every tick, so the harness sees what the server holds.
 */
final class Main extends PluginBase{

	private ?bool $last = null;

	protected function onEnable() : void{
		$this->getScheduler()->scheduleRepeatingTask(new ClosureTask(function() : void{
			$on = $this->getServer()->getWorldManager()->getAutoSave();
			if($on !== $this->last){
				$this->last = $on;
				$this->getLogger()->info("autosave " . ($on ? "on" : "off"));
			}
		}), 1);
	}
}
