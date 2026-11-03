<?php

/**
 * @name PacketLimitProbe
 * @main riftal\dev\packetlimit\Main
 * @version 0.0.1
 * @api 5.0.0
 * @depend RiftalDevBots
 * @description Self-test fixture for selftest.sh beside it. Never loaded by a stack.
 */

declare(strict_types=1);

namespace riftal\dev\packetlimit;

use pocketmine\event\server\NetworkInterfaceRegisterEvent;
use pocketmine\network\mcpe\raklib\RakLibInterface;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use function array_map;
use function count;
use function implode;
use function spl_object_id;

/**
 * Once the server ticks, lists the RakLib interfaces on the network by object
 * id, then announces the first of them again as a registration, and shuts
 * down. selftest.sh looks for each id in the packet limit lines of the log.
 */
final class Main extends PluginBase{

	protected function onEnable() : void{
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask($this->probe(...)), 1);
	}

	private function probe() : void{
		$server = $this->getServer();
		$raklib = [];
		foreach($server->getNetwork()->getInterfaces() as $interface){
			if($interface instanceof RakLibInterface){
				$raklib[] = $interface;
			}
		}
		$this->getLogger()->info("packet-limit-probe raklib=" . count($raklib) . " ids=" . implode(",", array_map(spl_object_id(...), $raklib)));

		if(count($raklib) > 0){
			$this->getLogger()->info("packet-limit-probe registration announced");
			(new NetworkInterfaceRegisterEvent($raklib[0]))->call();
		}
		$server->shutdown();
	}
}
