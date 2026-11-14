<?php

/**
 * @name RiftalDevFaults
 * @main riftal\dev\faults\Main
 * @version 0.3.0
 * @api 5.0.0
 * @depend RiftalDevBots
 * @softdepend RiftalCustody
 * @description Dev stack only. Fails a named player's saves, the custody probe, and one durable chunk save, for ADR 017 P8 and ADR 030, and fires one rank-up debit for ADR 034.
 */

declare(strict_types=1);

namespace riftal\dev\faults;

use Closure;
use Logger;
use pocketmine\command\Command;
use pocketmine\command\CommandSender;
use pocketmine\command\utils\InvalidCommandSyntaxException;
use pocketmine\console\ConsoleCommandSender;
use pocketmine\errorhandler\ErrorToExceptionHandler;
use pocketmine\event\EventPriority;
use pocketmine\event\player\PlayerDataSaveEvent;
use pocketmine\permission\DefaultPermissions;
use pocketmine\plugin\PluginBase;
use Ramsey\Uuid\Uuid;
use riftal\dev\bots\DevEnvGate;
use RiftalGames\Contracts\Accounts\AccountId;
use RiftalGames\Contracts\Chunk\DurableChunkSaveEvent;
use RiftalGames\Contracts\Currency;
use RiftalGames\Contracts\Economy\CurrencyDebitRequestedEvent;
use RiftalGames\Contracts\Economy\CurrencyMovementReason;
use RiftalGames\Contracts\Economy\RequestId;
use RiftalGames\Contracts\InstanceIdentity;
use Symfony\Component\Filesystem\Path;
use function class_exists;
use function count;
use function filter_var;
use function getenv;
use function is_dir;
use function is_link;
use function mkdir;
use function preg_match;
use function rmdir;
use function strtolower;

/**
 * ADR 017 P8 needs one player's custody flush to fail and, in its case (a),
 * the probe as well, on a running dev stack.
 *
 * A cancelled PlayerDataSaveEvent is core's own failed save
 * (Server::saveOfflinePlayerData), which lib's DatFilePlayerSave observes at
 * MONITOR as a failed flush. An empty directory at the probe's path makes
 * core's Filesystem::safeFilePutContents throw, so the probe fails as it would
 * on storage that cannot be written.
 *
 * Present only under RiftalDevBots' DevEnvGate: without --riftal-dev-bots=on,
 * xbox-auth off and RIFTAL_DEV_ENV=1, no command and no listener exist, and
 * without RiftalDevBots core refuses to load this plugin at all.
 * dev-faults/selftest.sh holds the gate, every fault and the boot order.
 *
 * The gate is read and the armed probe cleared in onLoad, because core runs
 * every plugin's onLoad before it enables any, and custody runs its boot
 * probe when it enables. The softdepend on RiftalCustody is ADR 013's, held
 * by custody-selftest.sh for every script plugin an instance loads.
 *
 * ADR 030's chunk fault cancels lib's DurableChunkSaveEvent, a RiftalContracts
 * class, which lib fires only behind the same gate. A script header holds one
 * softdepend, and custody has it, so the event is looked up in onEnable:
 * RiftalContracts loads at STARTUP and core puts every plugin's classes on the
 * loader before it enables any. Without RiftalContracts the other two faults
 * still register and the chunk fault does not.
 *
 * devfaults-debit (ADR 034) fires one CurrencyDebitRequestedEvent for rank_up
 * and nothing else. It keeps no state, retries nothing, reads no database and
 * never fires a credit, so the only money it can move is out of an account.
 * The reason is not an argument: another plugin reconciles on a reason, and a
 * console line must not be able to write one it has no matching row for.
 */
final class Main extends PluginBase{

	/** RiftalGames\Lib\Player\DatFilePlayerSave::PROBE_FILE in riftal-game. */
	public const PROBE_FILE = ".custody-probe";

	/** @var array<string, true> lowercase names whose every save is cancelled until the process ends */
	private array $failing = [];

	/**
	 * Each one fails a single durable save and is then gone. Keyed on the
	 * chunk as well as the level, because plots saves through the same call
	 * and an unkeyed fault could be spent on the wrong chunk.
	 *
	 * @var array<string, true> chunkKey() of each armed chunk
	 */
	private array $chunkFaults = [];

	private bool $on = false;

	protected function onLoad() : void{
		$server = $this->getServer();
		$envValue = getenv(DevEnvGate::ENV_VAR);
		$this->on = DevEnvGate::shouldAdmit(
			$server->getConfigGroup()->getConfigBool("riftal-dev-bots", false),
			$server->requiresAuthentication(),
			$envValue === false ? null : $envValue
		);
		$this->getLogger()->info("dev faults " . ($this->on ? "on" : "off"));
		if(!$this->on){
			return;
		}
		$this->clearProbeFailure();
	}

	protected function onEnable() : void{
		if(!$this->on){
			return;
		}
		$server = $this->getServer();
		$events = $server->getPluginManager();
		$events->registerEvent(PlayerDataSaveEvent::class, $this->onSave(...), EventPriority::HIGHEST, $this);
		$logger = $this->getLogger();
		$commands = [
			new FaultCommand("devfaults-flush-fail", "Dev stack only. Cancels every save of one player until this process ends.", "/devfaults-flush-fail <player>", $logger, $this->failFlush(...)),
			new FaultCommand("devfaults-probe-fail", "Dev stack only. Makes the custody probe fail until the next boot.", "/devfaults-probe-fail", $logger, $this->failProbe(...)),
		];
		if(class_exists(DurableChunkSaveEvent::class)){
			$events->registerEvent(DurableChunkSaveEvent::class, $this->onChunkSave(...), EventPriority::HIGHEST, $this);
			$commands[] = new FaultCommand("devfaults-chunk-save-fail", "Dev stack only. Fails the next durable save of one chunk.", "/devfaults-chunk-save-fail <level> <chunkX> <chunkZ>", $logger, $this->failChunkSave(...));
		}else{
			$logger->warning("RiftalContracts is not loaded, so devfaults-chunk-save-fail is not registered");
		}
		if(class_exists(CurrencyDebitRequestedEvent::class)){
			$commands[] = new FaultCommand("devfaults-debit", "Dev stack only. Debits one account once, with the reason rank_up.", "/devfaults-debit <account id> <amount minor units>", $logger, $this->debit(...));
		}else{
			$logger->warning("RiftalContracts is not loaded, so devfaults-debit is not registered");
		}
		$server->getCommandMap()->registerAll("riftaldevfaults", $commands);
	}

	/** @param list<string> $args */
	private function debit(array $args) : string{
		if(count($args) !== 2){
			throw new InvalidCommandSyntaxException();
		}
		$account = self::positiveInt($args[0]);
		$amount = self::positiveInt($args[1]);
		if($account === null || $amount === null){
			throw new InvalidCommandSyntaxException();
		}
		try{
			$instance = InstanceIdentity::fromEnvironment(getenv("INSTANCE_ID"));
		}catch(\InvalidArgumentException $e){
			return "no debit is fired: " . $e->getMessage();
		}
		$requestId = RequestId::fromString(Uuid::uuid7()->toString());
		$logger = $this->getLogger();
		$line = "devfaults-debit request_id={$requestId->toString()} account_id=$account amount_minor_units=$amount instance_id={$instance->id()}";
		$outcome = static fn(string $name) : Closure => static function() use ($logger, $line, $name) : void{
			$logger->info("$line outcome=$name");
		};
		$logger->info("$line reason=" . CurrencyMovementReason::RankUp->value);
		(new CurrencyDebitRequestedEvent(
			$instance,
			AccountId::fromInt($account),
			Currency::fromMinorUnits($amount),
			$outcome("debited"),
			$outcome("rejected"),
			$outcome("failed"),
			$requestId,
			CurrencyMovementReason::RankUp,
			$outcome("not_applied")
		))->call();
		return "";
	}

	/** Only a plain decimal count of at least 1 that fits an int. */
	private static function positiveInt(string $value) : ?int{
		if(preg_match('/\A[1-9][0-9]*\z/', $value) !== 1){
			return null;
		}
		$int = filter_var($value, FILTER_VALIDATE_INT);
		return $int === false ? null : $int;
	}

	private function onChunkSave(DurableChunkSaveEvent $event) : void{
		$level = $event->getWorld()->getFolderName();
		$key = self::chunkKey($level, $event->chunkX(), $event->chunkZ());
		if(isset($this->chunkFaults[$key])){
			unset($this->chunkFaults[$key]);
			$event->cancel();
			$this->getLogger()->info("cancelled the durable save of chunk {$event->chunkX()} {$event->chunkZ()} in $level");
		}
	}

	/** @param list<string> $args */
	private function failChunkSave(array $args) : string{
		if(count($args) !== 3){
			throw new InvalidCommandSyntaxException();
		}
		[$level, $x, $z] = $args;
		$chunkX = filter_var($x, FILTER_VALIDATE_INT);
		$chunkZ = filter_var($z, FILTER_VALIDATE_INT);
		if($chunkX === false || $chunkZ === false){
			throw new InvalidCommandSyntaxException();
		}
		if($this->getServer()->getWorldManager()->getWorldByName($level) === null){
			return "no level $level is loaded on this instance, so nothing is armed";
		}
		$this->chunkFaults[self::chunkKey($level, $chunkX, $chunkZ)] = true;
		return "the next durable save of chunk $chunkX $chunkZ in $level fails";
	}

	private static function chunkKey(string $level, int $chunkX, int $chunkZ) : string{
		return "$chunkX:$chunkZ:$level";
	}

	private function onSave(PlayerDataSaveEvent $event) : void{
		$name = strtolower($event->getPlayerName());
		if(isset($this->failing[$name])){
			$event->cancel();
			$this->getLogger()->info("cancelled the save of $name");
		}
	}

	/** @param list<string> $args */
	private function failFlush(array $args) : string{
		if(count($args) !== 1){
			throw new InvalidCommandSyntaxException();
		}
		$name = strtolower($args[0]);
		$this->failing[$name] = true;
		return "every save of $name is cancelled until this process ends";
	}

	/** @param list<string> $args */
	private function failProbe(array $args) : string{
		if(count($args) !== 0){
			throw new InvalidCommandSyntaxException();
		}
		$path = $this->probePath();
		if(!is_dir($path)){
			try{
				ErrorToExceptionHandler::trapAndRemoveFalse(static fn() => mkdir($path));
			}catch(\ErrorException $e){
				return "could not arm the probe failure at $path: " . $e->getMessage();
			}
		}
		return "the custody probe fails until the next boot: $path is a directory";
	}

	/**
	 * Left in place, the directory would fail custody's boot probe (ADR 017
	 * item 5) and kill this boot, which is why this runs in onLoad. rmdir
	 * removes only an empty directory, so a file
	 * of that name, or anything put inside it, is never touched.
	 */
	private function clearProbeFailure() : void{
		$path = $this->probePath();
		if(is_link($path) || !is_dir($path)){
			return;
		}
		try{
			ErrorToExceptionHandler::trapAndRemoveFalse(static fn() => rmdir($path));
			$this->getLogger()->info("cleared the custody probe failure armed before this boot");
		}catch(\ErrorException $e){
			$this->getLogger()->warning("could not clear the custody probe failure at $path: " . $e->getMessage());
		}
	}

	private function probePath() : string{
		return Path::join($this->getServer()->getDataPath(), "players", self::PROBE_FILE);
	}
}

/**
 * Runnable only from the server console: a player who could run one could
 * make anyone's progress unsaveable.
 */
final class FaultCommand extends Command{

	/** @param Closure(list<string>) : string $run returns the line to log, or "" when it has logged its own */
	public function __construct(string $name, string $description, string $usage, private Logger $logger, private Closure $run){
		parent::__construct($name, $description, $usage);
		$this->setPermission(DefaultPermissions::ROOT_CONSOLE);
	}

	public function execute(CommandSender $sender, string $commandLabel, array $args) : bool{
		if(!$sender instanceof ConsoleCommandSender){
			$sender->sendMessage($this->getName() . " runs only from the server console");
			return true;
		}
		$line = ($this->run)($args);
		if($line !== ""){
			$this->logger->warning($this->getName() . ": " . $line);
		}
		return true;
	}
}
