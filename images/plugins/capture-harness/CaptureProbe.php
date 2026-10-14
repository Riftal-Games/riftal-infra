<?php

/**
 * @name CaptureProbe
 * @main riftal\captureprobe\Main
 * @version 0.1.0
 * @api 5.0.0
 * @description Loaded only by capture-harness/harness.sh: logs the server's autosave flag whenever it changes, and answers its console probes.
 */

declare(strict_types=1);

namespace riftal\captureprobe;

use pocketmine\block\VanillaBlocks;
use pocketmine\event\Listener;
use pocketmine\event\server\CommandEvent;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\world\generator\Flat;
use pocketmine\world\WorldCreationOptions;

/**
 * RiftalCapture's release line reports the value it meant to set. This reads
 * the flag itself, every tick, so the harness sees what the server holds.
 *
 * The console probes, each answered with one log line:
 * - "probe chunk-set" sets a glass block in a chunk three chunks east of
 *   spawn, outside the spawn chunks core never unloads;
 * - "probe chunk-unload" asks core to unload that chunk;
 * - "probe chunk-read" loads the chunk, from disk when it was unloaded, and
 *   names the block;
 * - "probe level-make" makes a second, empty level, and "probe level-drop"
 *   asks core for an unforced unload of it.
 */
final class Main extends PluginBase implements Listener{

	private const LEVEL = "probe_b";
	private const Y = 40;

	private ?bool $last = null;

	protected function onEnable() : void{
		$this->getServer()->getPluginManager()->registerEvents($this, $this);
		$this->getScheduler()->scheduleRepeatingTask(new ClosureTask(function() : void{
			$on = $this->getServer()->getWorldManager()->getAutoSave();
			if($on !== $this->last){
				$this->last = $on;
				$this->getLogger()->info("autosave " . ($on ? "on" : "off"));
			}
		}), 1);
	}

	public function onProbe(CommandEvent $event) : void{
		$words = explode(" ", $event->getCommand());
		if($words[0] !== "probe" || !isset($words[1])){
			return;
		}
		$event->cancel();
		$worlds = $this->getServer()->getWorldManager();
		$world = $worlds->getDefaultWorld();
		$spawn = $world->getSpawnLocation();
		$cx = ($spawn->getFloorX() >> 4) + 3;
		$cz = $spawn->getFloorZ() >> 4;
		$x = ($cx << 4) + 1;
		$z = ($cz << 4) + 1;
		$say = fn(string $line) => $this->getLogger()->info($line);
		switch($words[1]){
			case "chunk-set":
				$world->orderChunkPopulation($cx, $cz, null)->onCompletion(
					function() use ($world, $x, $z, $say) : void{
						$world->setBlockAt($x, self::Y, $z, VanillaBlocks::GLASS());
						$say("chunk-set: done");
					},
					fn() => $say("chunk-set: failed")
				);
				break;
			case "chunk-unload":
				$unloaded = $world->unloadChunk($cx, $cz);
				$say("chunk-unload: " . ($unloaded ? "true" : "false") . ", loaded: " . ($world->isChunkLoaded($cx, $cz) ? "yes" : "no"));
				break;
			case "chunk-read":
				$world->loadChunk($cx, $cz);
				$block = $world->getBlockAt($x, self::Y, $z);
				$say("chunk-read: " . ($block->getTypeId() === VanillaBlocks::GLASS()->getTypeId() ? "glass" : $block->getName()));
				break;
			case "level-make":
				$made = $worlds->generateWorld(self::LEVEL, WorldCreationOptions::create()->setGeneratorClass(Flat::class), false);
				$say("level-make: " . ($made ? "true" : "false"));
				break;
			case "level-drop":
				$level = $worlds->getWorldByName(self::LEVEL);
				$say("level-drop: " . ($level === null ? "missing" : ($worlds->unloadWorld($level) ? "true" : "false")));
				break;
		}
	}
}
