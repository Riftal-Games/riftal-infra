<?php

/**
 * @name PacketLimitProbe
 * @main riftal\dev\packetlimit\Main
 * @version 0.0.2
 * @api 5.0.0
 * @depend RiftalDevBots
 * @description Self-test fixture for selftest.sh beside it. Never loaded by a stack.
 */

declare(strict_types=1);

namespace riftal\dev\packetlimit;

use Closure;
use pocketmine\event\EventPriority;
use pocketmine\event\server\NetworkInterfaceRegisterEvent;
use pocketmine\network\mcpe\raklib\RakLibInterface;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use raklib\server\ipc\InterThreadChannelWriter;
use raklib\server\ipc\UserToRakLibThreadMessageSender;
use ReflectionProperty;
use function array_map;
use function count;
use function implode;
use function spl_object_id;

/**
 * The sender RakLibInterface hands its limit to. The limit goes on to the
 * RakLib thread and cannot be read back, so this reports each value as it
 * passes, which is the one place the call and its argument are visible.
 */
final class RecordingSender extends UserToRakLibThreadMessageSender{

	/** @param Closure(int) : void $onLimit */
	public function __construct(InterThreadChannelWriter $channel, private Closure $onLimit){
		parent::__construct($channel);
	}

	public function setPacketsPerTickLimit(int $limit) : void{
		($this->onLimit)($limit);
		parent::setPacketsPerTickLimit($limit);
	}
}

/**
 * Wraps the sender of every RakLib interface as it registers, ahead of
 * RiftalDevBots' MONITOR handler. Once the server ticks, lists the RakLib
 * interfaces on the network by object id, then announces the first of them
 * again as a registration, and shuts down. selftest.sh looks for each id in
 * the observed limit lines of the log.
 */
final class Main extends PluginBase{

	protected function onEnable() : void{
		$this->getServer()->getPluginManager()->registerEvent(
			NetworkInterfaceRegisterEvent::class,
			fn(NetworkInterfaceRegisterEvent $event) => $this->observe($event->getInterface()),
			EventPriority::LOWEST,
			$this
		);
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask($this->probe(...)), 1);
	}

	private function observe(object $interface) : void{
		if(!$interface instanceof RakLibInterface){
			return;
		}
		$sender = new ReflectionProperty(RakLibInterface::class, "interface");
		$current = $sender->getValue($interface);
		if($current instanceof RecordingSender){
			return;
		}
		$channel = (new ReflectionProperty(UserToRakLibThreadMessageSender::class, "channel"))->getValue($current);
		$id = spl_object_id($interface);
		$logger = $this->getLogger();
		$sender->setValue($interface, new RecordingSender(
			$channel,
			static fn(int $limit) => $logger->info("packet-limit-probe observed setPacketsPerTickLimit($limit) on interface $id")
		));
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
