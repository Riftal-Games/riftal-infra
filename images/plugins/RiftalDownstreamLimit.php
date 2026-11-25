<?php

/**
 * @name RiftalDownstreamLimit
 * @main riftal\infra\downstream\Main
 * @version 0.1.0
 * @api 5.0.0
 * @softdepend RiftalCustody
 * @description On an instance configured as a downstream behind the proxy, turns off RakLib's per-address packet limit and lifts its bad-packet block of the proxy's address.
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
use function array_unique;
use function array_values;
use function explode;
use function filter_var;
use function implode;
use function inet_ntop;
use function inet_pton;
use function spl_object_id;
use function trim;
use const FILTER_VALIDATE_IP;

/**
 * Applies only when the instance's service definition passes
 * --riftal-downstream=on (a riftal-downstream=on line in server.properties
 * also counts) and xbox-auth is off. Anything else makes no call and logs
 * that it made none; the network is never consulted.
 *
 * The block lift also needs --riftal-downstream-proxies, a comma separated
 * list of the proxy's addresses set by the service definition. The list is
 * never learned from traffic.
 */
final class Main extends PluginBase{

	// RakLib counts datagrams per source address and blocks the address for
	// 300 s at its limit, 200 by default. Behind the proxy every player reaches
	// a downstream from the proxy's one address, so any finite limit puts the
	// whole instance in one bucket, and a trip times out every session on it.
	// A downstream publishes no port, so the proxy is the only sender and the
	// limit guards nothing; it is off rather than merely higher.
	public const PACKET_LIMIT = PHP_INT_MAX;

	// A bad game packet makes core block the sender's address for 5 s (100
	// ticks), and RakLib drops every datagram from a blocked address, so behind
	// the proxy one session's bad packet silences every session on the
	// downstream. Core sends the block after the disconnect on the same channel,
	// so an unblock sent in that same tick is overtaken by it; the next tick is
	// the earliest one that lifts it, which bounds the drops to one tick. No
	// event fires for a session that was never a player, so the unblock runs
	// every tick and waits for none.
	public const UNBLOCK_INTERVAL_TICKS = 1;

	protected function onEnable() : void{
		$server = $this->getServer();
		$optedIn = $server->getConfigGroup()->getConfigBool("riftal-downstream", false);
		if(!$optedIn || $server->requiresAuthentication()){
			$why = $optedIn ? "xbox-auth is on" : "riftal-downstream is not set";
			$this->getLogger()->info("downstream packet limit not raised: " . $why);
			$this->getLogger()->info("proxy address unblock not started: " . $why);
			return;
		}

		$proxies = $this->listedProxies($server->getConfigGroup()->getConfigString("riftal-downstream-proxies", ""));
		if($proxies === []){
			$this->getLogger()->info("proxy address unblock not started: riftal-downstream-proxies lists no address");
		}else{
			$server->getPluginManager()->registerEvent(
				NetworkInterfaceRegisterEvent::class,
				fn(NetworkInterfaceRegisterEvent $event) => $this->unblockEvery($event->getInterface(), $proxies),
				EventPriority::MONITOR,
				$this
			);
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

	/**
	 * @return list<string> the listed addresses in the form RakLib keys its
	 *   blocks by, without anything that is not an IP address
	 */
	private function listedProxies(string $list) : array{
		$proxies = [];
		foreach(explode(",", $list) as $entry){
			$entry = trim($entry);
			if($entry === ""){
				continue;
			}
			if(filter_var($entry, FILTER_VALIDATE_IP) === false){
				$this->getLogger()->info("proxy address unblock ignores \"$entry\": not an IP address");
				continue;
			}
			$proxies[] = inet_ntop(inet_pton($entry));
		}
		return array_values(array_unique($proxies));
	}

	/**
	 * @param list<string> $proxies
	 */
	private function unblockEvery(NetworkInterface $interface, array $proxies) : void{
		if(!$interface instanceof RakLibInterface){
			return;
		}
		$this->getScheduler()->scheduleRepeatingTask(new ClosureTask(static function() use ($interface, $proxies) : void{
			foreach($proxies as $address){
				$interface->unblockAddress($address);
			}
		}), self::UNBLOCK_INTERVAL_TICKS);
		$this->getLogger()->info("proxy address " . implode(",", $proxies) . " unblocked every " . self::UNBLOCK_INTERVAL_TICKS . " tick on interface " . spl_object_id($interface));
	}
}
