<?php

/**
 * @name RiftalDownstreamLimit
 * @main riftal\infra\downstream\Main
 * @version 0.1.0
 * @api 5.0.0
 * @softdepend RiftalCustody
 * @description Turns off RakLib's per-address packet limit on an instance configured as a downstream behind the proxy.
 */

// The softdepend keeps RiftalCustody enabled until this plugin has disabled
// (ADR 013, item 2).

declare(strict_types=1);

namespace riftal\infra\downstream;

use pocketmine\event\EventPriority;
use pocketmine\event\server\NetworkInterfaceRegisterEvent;
use pocketmine\network\mcpe\raklib\RakLibInterface;
use pocketmine\network\NetworkInterface;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use function spl_object_id;

/**
 * Applies only when the instance's service definition passes
 * --riftal-downstream=on (a riftal-downstream=on line in server.properties
 * also counts) and xbox-auth is off. Anything else makes no call and logs
 * that it made none; the network is never consulted.
 */
final class Main extends PluginBase{

	// RakLib counts datagrams per source address and blocks the address for
	// 300 s at its limit, 200 by default. Behind the proxy every player reaches
	// a downstream from the proxy's one address, so any finite limit puts the
	// whole instance in one bucket, and a trip times out every session on it.
	// A downstream publishes no port, so the proxy is the only sender and the
	// limit guards nothing; it is off rather than merely higher.
	public const PACKET_LIMIT = PHP_INT_MAX;

	protected function onEnable() : void{
		$server = $this->getServer();
		$optedIn = $server->getConfigGroup()->getConfigBool("riftal-downstream", false);
		if(!$optedIn || $server->requiresAuthentication()){
			$this->getLogger()->info(
				"downstream packet limit not raised: " . ($optedIn ? "xbox-auth is on" : "riftal-downstream is not set")
			);
			return;
		}

		// Plugins enable before the network interfaces start, so the register
		// event is the only way to reach each RakLib interface.
		$server->getPluginManager()->registerEvent(
			NetworkInterfaceRegisterEvent::class,
			fn(NetworkInterfaceRegisterEvent $event) => $this->disableLater($event->getInterface()),
			EventPriority::MONITOR,
			$this
		);
	}

	// The call waits a tick because core shuffles plugin load order on every
	// boot, so handlers of one event run in no fixed order, and RiftalDevBots
	// sets its own, lower limit from this same event. A call a tick later is
	// always the last.
	private function disableLater(NetworkInterface $interface) : void{
		if(!$interface instanceof RakLibInterface){
			return;
		}
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask(function() use ($interface) : void{
			$interface->setPacketLimit(self::PACKET_LIMIT);
			$this->getLogger()->info("downstream packet limit off on interface " . spl_object_id($interface));
		}), 1);
	}
}
