<?php

/**
 * @name RiftalDevProofs
 * @main riftal\dev\proofs\Main
 * @version 0.1.0
 * @api 5.0.0
 * @depend RiftalDevBots
 * @softdepend RiftalCustody
 * @description Dev stack only. Sends every client that joins (a dev bot excepted) the effects proofs of docs/effects/plan.md section 10, 20 seconds after it joins, and answers the client's settings request.
 */

declare(strict_types=1);

namespace riftal\dev\proofs;

use Closure;
use pocketmine\event\EventPriority;
use pocketmine\event\player\PlayerJoinEvent;
use pocketmine\event\server\DataPacketReceiveEvent;
use pocketmine\math\Vector3;
use pocketmine\network\mcpe\protocol\CameraShakePacket;
use pocketmine\network\mcpe\protocol\ClientboundPacket;
use pocketmine\network\mcpe\protocol\ModalFormResponsePacket;
use pocketmine\network\mcpe\protocol\PlayerFogPacket;
use pocketmine\network\mcpe\protocol\PlaySoundPacket;
use pocketmine\network\mcpe\protocol\ServerSettingsRequestPacket;
use pocketmine\network\mcpe\protocol\ServerSettingsResponsePacket;
use pocketmine\network\mcpe\protocol\SpawnParticleEffectPacket;
use pocketmine\network\mcpe\protocol\StopSoundPacket;
use pocketmine\network\mcpe\protocol\types\DimensionIds;
use pocketmine\player\Player;
use pocketmine\plugin\PluginBase;
use pocketmine\scheduler\ClosureTask;
use riftal\dev\bots\DevEnvGate;
use riftal\dev\bots\Main as DevBots;
use function array_values;
use function count;
use function getenv;
use function implode;
use function is_string;
use function json_encode;
use function max;
use function microtime;
use function round;
use function sprintf;
use function usort;
use const JSON_PRESERVE_ZERO_FRACTION;
use const JSON_THROW_ON_ERROR;

/**
 * One packet-sending moment of the proofs: when it runs, the id the log line
 * carries, and what it builds from the player's position at that moment and
 * the direction they face. A step that builds nothing is a log sample.
 */
final class ProofStep{

	/** @param Closure(Vector3, Vector3) : list<ClientboundPacket> $build */
	public function __construct(
		public readonly float $atSeconds,
		public readonly string $id,
		public readonly Closure $build
	){}
}

/**
 * The timed sequence, a pure function of nothing but the constants below, so
 * dev-proofs/selftest.sh can build and encode every packet without a client.
 */
final class ProofSequence{

	/** Seconds after the join before the first step. */
	public const START_DELAY_SECONDS = 20.0;

	public const VANILLA_FOG = "minecraft:fog_hell";
	public const VANILLA_FOG_OTHER = "minecraft:fog_the_end";
	public const PACK_FOG = "riftal:proof_fog";
	public const PACK_SOUND = "riftal.proof.tone";
	public const PACK_PARTICLE = "riftal:proof_dust";
	public const LOGO_PARTICLE = "bbstudio:ash_burst";

	/**
	 * Opt-in on top of DevEnvGate. The shared dev stack admits every instance
	 * through the gate, so the sequence would otherwise run on every client that
	 * joins it and the LOWEST settings handler would hide the effects settings
	 * form. Only the exact value 1 admits, and nothing committed sets it.
	 */
	public const OPT_IN_ENV_VAR = "RIFTAL_DEV_PROOFS";

	/**
	 * The proof tone's length. It sets the carry walk, which has to outlast a
	 * 40 block walk at walking pace, and the re-send interval of proof 4d,
	 * which is one tick short of it. The studio's tone must be this long.
	 */
	public const TONE_SECONDS = 12.0;

	/** The settings form's id, high enough to clear Player::sendForm's counter. */
	public const SETTINGS_FORM_ID = 0x52460001;

	/** @return list<ProofStep> in the order they run */
	public static function steps() : array{
		$fog = static fn(string ...$layers) : Closure => static fn() : array => [PlayerFogPacket::create(array_values($layers))];
		$tone = static fn(float $volume, int $loops, bool $bypass, float $dx = 0.0) : Closure =>
			static fn(Vector3 $pos) : array => [PlaySoundPacket::create(self::PACK_SOUND, $pos->x + $dx, $pos->y, $pos->z, $volume, 1.0, $loops, $bypass, null, null)];
		$dust = static fn(float $r, float $g, float $b) : Closure => static fn(Vector3 $pos, Vector3 $facing) : array => [
			SpawnParticleEffectPacket::create(DimensionIds::OVERWORLD, -1, self::ahead($pos, $facing), self::PACK_PARTICLE, self::molangColour($r, $g, $b)),
		];
		$sample = static fn() : array => [];
		$resend = self::TONE_SECONDS - 0.05;

		$steps = [
			new ProofStep(0.0, "1a-vanilla-fog", $fog(self::VANILLA_FOG)),
			new ProofStep(8.0, "1b-pack-fog", $fog(self::PACK_FOG)),
			new ProofStep(16.0, "1c-empty-stack", $fog()),
			new ProofStep(22.0, "1d-stack-a", $fog(self::VANILLA_FOG)),
			new ProofStep(28.0, "1d-stack-b", $fog(self::VANILLA_FOG_OTHER)),
			new ProofStep(36.0, "1d-empty-stack", $fog()),
			new ProofStep(44.0, "2-shake", static fn() : array => [
				CameraShakePacket::create(1.0, 2.0, CameraShakePacket::TYPE_ROTATIONAL, CameraShakePacket::ACTION_ADD),
			]),
		];
		for($i = 0; $i < 5; $i++){
			$steps[] = new ProofStep(52.0 + $i, "3a-ash-burst", static fn(Vector3 $pos, Vector3 $facing) : array => [
				SpawnParticleEffectPacket::create(DimensionIds::OVERWORLD, -1, self::ahead($pos, $facing), self::LOGO_PARTICLE, null),
			]);
			$steps[] = new ProofStep(62.0 + $i, "3b-dust-red", $dust(1.0, 0.1, 0.1));
			$steps[] = new ProofStep(70.0 + $i, "3b-dust-blue", $dust(0.1, 0.3, 1.0));
		}
		$steps[] = new ProofStep(82.0, "4a-tone-by-name", $tone(1.0, 0, false));
		$steps[] = new ProofStep(96.0, "4b-carry-send", $tone(1.0, 0, false));
		foreach([3.0, 6.0, 9.0, 12.0] as $walked){
			$steps[] = new ProofStep(96.0 + $walked, "4b-carry-sample", $sample);
		}
		$steps[] = new ProofStep(116.0, "4c-tone", $tone(1.0, 0, false));
		$steps[] = new ProofStep(119.0, "4c-stop", static fn() : array => [StopSoundPacket::create(self::PACK_SOUND, false, false)]);
		for($i = 0; $i < 3; $i++){
			$steps[] = new ProofStep(126.0 + $i * $resend, "4d-resend", $tone(1.0, 0, false));
		}
		$steps[] = new ProofStep(164.0, "4e-loop-count", $tone(1.0, 3, false));
		$steps[] = new ProofStep(190.0, "4e-stop", static fn() : array => [StopSoundPacket::create(self::PACK_SOUND, false, false)]);
		$far = 194.0;
		$steps[] = new ProofStep($far, "4f-far-no-bypass", $tone(1.0, 0, false, 100.0));
		$steps[] = new ProofStep($far + self::TONE_SECONDS, "4f-far-bypass", $tone(1.0, 0, true, 100.0));
		$steps[] = new ProofStep($far + self::TONE_SECONDS + 6.0, "5-open-settings-now", $sample);
		usort($steps, static fn(ProofStep $a, ProofStep $b) : int => $a->atSeconds <=> $b->atSeconds);
		return $steps;
	}

	/** The Settings screen's form: the two rows of plan section 6. */
	public static function settingsForm() : string{
		$row = static fn(string $text, string ...$options) : array => ["type" => "dropdown", "text" => $text, "options" => array_values($options), "default" => 0];
		return json_encode([
			"type" => "custom_form",
			"title" => "Riftal",
			"content" => [$row("Ambient sound", "Full", "Quiet", "Off"), $row("Screen effects", "Full", "Soft", "Off")],
		], JSON_THROW_ON_ERROR);
	}

	public static function molangColour(float $r, float $g, float $b) : string{
		$variable = static fn(string $name, float $value) : array => ["name" => "variable.$name", "value" => ["type" => "float", "value" => $value]];
		return json_encode([$variable("r", $r), $variable("g", $g), $variable("b", $b)], JSON_THROW_ON_ERROR | JSON_PRESERVE_ZERO_FRACTION);
	}

	public static function describe(ClientboundPacket $packet) : string{
		return match(true){
			$packet instanceof PlayerFogPacket => "PlayerFog layers=[" . implode(",", $packet->getFogLayers()) . "]",
			$packet instanceof CameraShakePacket => sprintf(
				"CameraShake intensity=%.2f duration=%.2f type=%d action=%d",
				$packet->getIntensity(), $packet->getDuration(), $packet->getShakeType(), $packet->getShakeAction()
			),
			$packet instanceof SpawnParticleEffectPacket => sprintf(
				"SpawnParticleEffect name=%s pos=%.2f,%.2f,%.2f molang=%s",
				$packet->particleName, $packet->position->x, $packet->position->y, $packet->position->z, $packet->molangVariablesJson ?? "none"
			),
			$packet instanceof PlaySoundPacket => sprintf(
				"PlaySound name=%s pos=%.2f,%.2f,%.2f volume=%.2f pitch=%.2f loopCount=%d bypassListenerRangeCheck=%s",
				$packet->soundName, $packet->x, $packet->y, $packet->z, $packet->volume, $packet->pitch, $packet->loopCount, $packet->bypassListenerRangeCheck ? "yes" : "no"
			),
			$packet instanceof StopSoundPacket => sprintf("StopSound name=%s stopAll=%s", $packet->soundName, $packet->stopAll ? "yes" : "no"),
			default => $packet->getName(),
		};
	}

	/** Three blocks in front of the player and one up, where a particle is in view. */
	private static function ahead(Vector3 $pos, Vector3 $facing) : Vector3{
		return $pos->add($facing->x * 3, 1, $facing->z * 3);
	}
}

/**
 * Plan section 10's proof sender. Present only under RiftalDevBots'
 * DevEnvGate and RIFTAL_DEV_PROOFS=1: without --riftal-dev-bots=on, xbox-auth
 * off, RIFTAL_DEV_ENV=1 and that opt-in no listener exists, and without
 * RiftalDevBots core refuses to load this plugin at all. It has no command.
 * A dev bot is skipped, since it renders nothing. dev-proofs/selftest.sh holds the gate, the sequence and the boot
 * refusals.
 *
 * Every send and every settings message is one server log line starting
 * "dev-proofs", with an epoch time in milliseconds, so the journey reads the
 * send log rather than guessing from the screen. The softdepend on
 * RiftalCustody is ADR 013's, held by custody-selftest.sh for every script
 * plugin an instance loads.
 */
final class Main extends PluginBase{

	private bool $on = false;

	protected function onLoad() : void{
		$server = $this->getServer();
		$envValue = getenv(DevEnvGate::ENV_VAR);
		$this->on = getenv(ProofSequence::OPT_IN_ENV_VAR) === "1" && DevEnvGate::shouldAdmit(
			$server->getConfigGroup()->getConfigBool("riftal-dev-bots", false),
			$server->requiresAuthentication(),
			$envValue === false ? null : $envValue
		);
		$this->getLogger()->info("dev proofs " . ($this->on ? "on" : "off"));
	}

	protected function onEnable() : void{
		if(!$this->on){
			return;
		}
		$events = $this->getServer()->getPluginManager();
		$events->registerEvent(PlayerJoinEvent::class, $this->onJoin(...), EventPriority::MONITOR, $this);
		$events->registerEvent(DataPacketReceiveEvent::class, $this->onPacket(...), EventPriority::LOWEST, $this);
	}

	private function onJoin(PlayerJoinEvent $event) : void{
		$player = $event->getPlayer();
		if(($player->getPlayerInfo()->getExtraData()["DeviceModel"] ?? null) === DevBots::BOT_DEVICE_MODEL){
			return;
		}
		$this->start($player, 1.0);
	}

	/**
	 * Schedules every step for $player. A join starts it at $speed 1, real
	 * time; dev-proofs/selftest.sh runs it faster so the whole sequence fits a
	 * boot.
	 */
	public function start(Player $player, float $speed) : void{
		if(!$this->on){
			return;
		}
		$this->log("start", $player, sprintf("steps=%d delay_seconds=%.0f", count(ProofSequence::steps()), ProofSequence::START_DELAY_SECONDS));
		$anchor = null;
		foreach(ProofSequence::steps() as $step){
			$ticks = max(1, (int) round(($step->atSeconds + ProofSequence::START_DELAY_SECONDS) * 20 / $speed));
			$this->getScheduler()->scheduleDelayedTask(new ClosureTask(function() use ($player, $step, &$anchor) : void{
				$this->run($player, $step, $anchor);
			}), $ticks);
		}
	}

	private function run(Player $player, ProofStep $step, ?Vector3 &$anchor) : void{
		if(!$player->isConnected()){
			return;
		}
		$pos = $player->getPosition()->asVector3();
		$packets = ($step->build)($pos, $player->getDirectionVector());
		$moved = $anchor === null ? 0.0 : $pos->distance($anchor);
		$sent = [];
		foreach($packets as $packet){
			$player->getNetworkSession()->sendDataPacket($packet);
			$sent[] = ProofSequence::describe($packet);
		}
		if($packets !== []){
			$anchor = $pos;
		}
		$this->log($step->id, $player, sprintf(
			"pos=%.1f,%.1f,%.1f moved_since_last_send=%.1f sent=%s",
			$pos->x, $pos->y, $pos->z, $moved, $sent === [] ? "none" : implode(" | ", $sent)
		));
	}

	private function onPacket(DataPacketReceiveEvent $event) : void{
		$packet = $event->getPacket();
		$session = $event->getOrigin();
		if($packet instanceof ServerSettingsRequestPacket){
			$event->cancel();
			$session->sendDataPacket(ServerSettingsResponsePacket::create(ProofSequence::SETTINGS_FORM_ID, ProofSequence::settingsForm()));
			$this->log("5-settings-request", $session->getPlayer(), "answered with form id " . ProofSequence::SETTINGS_FORM_ID);
		}elseif($packet instanceof ModalFormResponsePacket && $packet->formId === ProofSequence::SETTINGS_FORM_ID){
			$event->cancel();
			$this->log("5-settings-answer", $session->getPlayer(), sprintf(
				"data=%s cancel_reason=%s",
				is_string($packet->formData) ? $packet->formData : "none",
				$packet->cancelReason ?? "none"
			));
		}
	}

	private function log(string $id, ?Player $player, string $detail) : void{
		$this->getLogger()->info(sprintf(
			"dev-proofs %s player=%s t=%s %s",
			$id, $player?->getName() ?? "unknown", (string) round(microtime(true) * 1000), $detail
		));
	}
}
