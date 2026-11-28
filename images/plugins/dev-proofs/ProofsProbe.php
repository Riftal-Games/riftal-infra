<?php

/**
 * @name ProofsProbe
 * @main riftal\dev\proofsprobe\Main
 * @version 0.0.1
 * @api 5.0.0
 * @softdepend RiftalDevProofs
 * @description Self-test fixture for selftest.sh beside it. Never loaded by a stack.
 */

declare(strict_types=1);

namespace riftal\dev\proofsprobe;

use pmmp\encoding\ByteBufferWriter;
use pocketmine\entity\Skin;
use pocketmine\event\EventPriority;
use pocketmine\event\HandlerListManager;
use pocketmine\event\player\PlayerJoinEvent;
use pocketmine\event\server\DataPacketReceiveEvent;
use pocketmine\math\Vector3;
use pocketmine\network\mcpe\NetworkSession;
use pocketmine\network\mcpe\protocol\CameraShakePacket;
use pocketmine\network\mcpe\protocol\ClientboundPacket;
use pocketmine\network\mcpe\protocol\ModalFormResponsePacket;
use pocketmine\network\mcpe\protocol\PlayerFogPacket;
use pocketmine\network\mcpe\protocol\PlaySoundPacket;
use pocketmine\network\mcpe\protocol\ServerSettingsRequestPacket;
use pocketmine\network\mcpe\protocol\ServerSettingsResponsePacket;
use pocketmine\network\mcpe\protocol\SpawnParticleEffectPacket;
use pocketmine\network\mcpe\protocol\StopSoundPacket;
use pocketmine\player\Player;
use pocketmine\player\PlayerInfo;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use pocketmine\Server;
use pocketmine\world\Position;
use Ramsey\Uuid\Uuid;
use riftal\dev\proofs\ProofSequence;
use function array_filter;
use function array_map;
use function array_values;
use function class_exists;
use function count;
use function implode;
use function is_array;
use function json_decode;
use function sprintf;
use function str_repeat;
use function strlen;
use const JSON_THROW_ON_ERROR;

/** Records what a real session would send, and has no socket. */
final class ProbeSession extends NetworkSession{

	/** @var list<ClientboundPacket> */
	public array $sent = [];

	public ?Player $player = null;

	public function sendDataPacket(ClientboundPacket $packet, bool $immediate = false) : bool{
		$this->sent[] = $packet;
		return true;
	}

	public function getPlayer() : ?Player{
		return $this->player;
	}
}

/**
 * Stands in for a joined client without a network session, built without its
 * constructor, so it overrides everything the plugin under test calls on it.
 */
final class ProbePlayer extends Player{

	public ProbeSession $session;

	public string $deviceModel = "Windows";

	public function getName() : string{
		return Main::NAME;
	}

	public function getPlayerInfo() : PlayerInfo{
		return new PlayerInfo(
			Main::NAME,
			Uuid::uuid4(),
			new Skin("Standard_Custom", str_repeat("\x00", 64 * 32 * 4)),
			"en_US",
			["DeviceModel" => $this->deviceModel]
		);
	}

	public function getId() : int{
		return 1;
	}

	public function isConnected() : bool{
		return true;
	}

	public function getPosition() : Position{
		return new Position(10.0, 64.0, 10.0, Server::getInstance()->getWorldManager()->getDefaultWorld());
	}

	public function getDirectionVector() : Vector3{
		return new Vector3(1, 0, 0);
	}

	public function getNetworkSession() : NetworkSession{
		return $this->session;
	}

	public function __destruct(){
	}
}

final class Main extends PluginBase{

	public const NAME = "ProofsProbe";

	/** Runs the whole 226 s sequence in about five seconds. */
	private const SPEED = 50.0;

	protected function onEnable() : void{
		$this->getScheduler()->scheduleDelayedTask(new ClosureTask($this->probe(...)), 1);
	}

	private function probe() : void{
		$logger = $this->getLogger();
		$plugin = $this->getServer()->getPluginManager()->getPlugin("RiftalDevProofs");
		if($plugin === null || !class_exists(ProofSequence::class)){
			$logger->info("dev-proofs-probe plugin=absent");
			$this->getServer()->shutdown();
			return;
		}

		$listeners = static function(string $event) : int{
			$count = 0;
			foreach(EventPriority::ALL as $priority){
				foreach(HandlerListManager::global()->getListFor($event)->getListenersByPriority($priority) as $listener){
					if($listener->getPlugin()->getName() === "RiftalDevProofs"){
						$count++;
					}
				}
			}
			return $count;
		};
		$logger->info(sprintf(
			"dev-proofs-probe listeners join=%d packet=%d",
			$listeners(PlayerJoinEvent::class), $listeners(DataPacketReceiveEvent::class)
		));

		$steps = ProofSequence::steps();
		$packets = [];
		$sorted = true;
		$last = 0.0;
		foreach($steps as $step){
			$sorted = $sorted && $step->atSeconds >= $last;
			$last = $step->atSeconds;
			foreach(($step->build)(new Vector3(10, 64, 10), new Vector3(1, 0, 0)) as $packet){
				$out = new ByteBufferWriter();
				$packet->encode($out);
				$packets[] = [$packet, strlen($out->getData())];
			}
		}
		$logger->info(sprintf(
			"dev-proofs-probe sequence steps=%d packets=%d sorted=%s empty_encodings=%d first=%s last=%s",
			count($steps), count($packets), $sorted ? "yes" : "no",
			count(array_filter($packets, static fn(array $p) : bool => $p[1] === 0)),
			$steps[0]->id, $steps[count($steps) - 1]->id
		));

		$bot = $this->player("riftal-devbot");
		(new PlayerJoinEvent($bot, ""))->call();
		$player = $this->player("Windows");
		(new PlayerJoinEvent($player, ""))->call();
		$plugin->start($player, self::SPEED);

		$this->getScheduler()->scheduleDelayedTask(new ClosureTask(fn() => $this->finish($player, $bot)), 140);
	}

	private function player(string $deviceModel) : ProbePlayer{
		$player = (new \ReflectionClass(ProbePlayer::class))->newInstanceWithoutConstructor();
		$player->deviceModel = $deviceModel;
		$player->session = (new \ReflectionClass(ProbeSession::class))->newInstanceWithoutConstructor();
		$player->session->player = $player;
		return $player;
	}

	private function finish(ProbePlayer $player, ProbePlayer $bot) : void{
		$count = static function(ProbePlayer $p, string $class) : int{
			return count(array_filter($p->session->sent, static fn(ClientboundPacket $s) : bool => $s instanceof $class));
		};
		$this->getLogger()->info(sprintf(
			"dev-proofs-probe sent=%d fog=%d shake=%d particle=%d sound=%d stop=%d bot_sent=%d",
			count($player->session->sent), $count($player, PlayerFogPacket::class), $count($player, CameraShakePacket::class),
			$count($player, SpawnParticleEffectPacket::class), $count($player, PlaySoundPacket::class),
			$count($player, StopSoundPacket::class), count($bot->session->sent)
		));

		$request = new DataPacketReceiveEvent($player->session, ServerSettingsRequestPacket::create());
		$request->call();
		$answers = array_filter($player->session->sent, static fn(ClientboundPacket $s) : bool => $s instanceof ServerSettingsResponsePacket);
		$answer = $answers === [] ? null : array_values($answers)[0];
		$form = $answer === null ? null : json_decode($answer->formData, true, 8, JSON_THROW_ON_ERROR);
		$rows = is_array($form) && is_array($form["content"] ?? null) ? array_map(static fn(array $r) : string => $r["type"] . ":" . implode("/", $r["options"]), $form["content"]) : [];

		$ours = new DataPacketReceiveEvent($player->session, ModalFormResponsePacket::response(ProofSequence::SETTINGS_FORM_ID, "[1,2]"));
		$ours->call();
		$other = new DataPacketReceiveEvent($player->session, ModalFormResponsePacket::response(ProofSequence::SETTINGS_FORM_ID + 1, "[0,0]"));
		$other->call();
		$this->getLogger()->info(sprintf(
			"dev-proofs-probe settings request_cancelled=%s answered=%s form_id=%s rows=%s answer_cancelled=%s other_form_cancelled=%s",
			$request->isCancelled() ? "yes" : "no", $answer === null ? "no" : "yes",
			$answer === null ? "none" : ($answer->formId === ProofSequence::SETTINGS_FORM_ID ? "fixed" : "wrong"),
			implode(",", $rows), $ours->isCancelled() ? "yes" : "no", $other->isCancelled() ? "yes" : "no"
		));
		$this->getServer()->shutdown();
	}
}
