<?php

/**
 * @name RiftalContracts
 * @main riftal\dev\faultscontracts\Main
 * @version 0.0.1
 * @api 5.0.0
 * @load STARTUP
 * @description Self-test fixture for selftest.sh beside it, standing in for riftal-game's contracts. Never loaded by a stack.
 */

declare(strict_types=1);

namespace riftal\dev\faultscontracts;

use pocketmine\plugin\PluginBase;

/**
 * Named and loaded as riftal-game's RiftalContracts is, so RiftalDevFaults
 * finds the event class the way it would on an instance. CI has no riftal-game
 * checkout to build the real phar from.
 */
final class Main extends PluginBase{
}

namespace RiftalGames\Contracts\Chunk;

use pocketmine\event\Cancellable;
use pocketmine\event\CancellableTrait;
use pocketmine\event\world\WorldEvent;
use pocketmine\world\World;

/**
 * The shape of riftal-game's contracts/src/RiftalGames/Contracts/Chunk/
 * DurableChunkSaveEvent.php (ADR 030): a cancellable WorldEvent carrying the
 * chunk's X and Z. A change there is carried here by hand.
 */
final class DurableChunkSaveEvent extends WorldEvent implements Cancellable{
	use CancellableTrait;

	public function __construct(
		World $world,
		private readonly int $chunkX,
		private readonly int $chunkZ
	){
		parent::__construct($world);
	}

	public function chunkX() : int{
		return $this->chunkX;
	}

	public function chunkZ() : int{
		return $this->chunkZ;
	}
}
