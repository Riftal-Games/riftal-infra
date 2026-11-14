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

namespace RiftalGames\Contracts;

use InvalidArgumentException;

/**
 * The shapes of riftal-game's InstanceIdentity, Currency, QueryFailure and
 * Economy\RequestId, Accounts\AccountId and Economy\CurrencyDebitRequestedEvent
 * (ADR 034), keeping the validation RiftalDevFaults depends on. A change there
 * is carried here by hand.
 */
final class InstanceIdentity{
	private function __construct(private readonly string $id){}

	public static function fromEnvironment(string|false $envInstanceId) : self{
		if($envInstanceId === false || $envInstanceId === ""){
			throw new InvalidArgumentException("INSTANCE_ID is required and must be a non-empty string");
		}
		return new self($envInstanceId);
	}

	public function id() : string{
		return $this->id;
	}
}

final class Currency{
	private function __construct(private readonly int $minorUnits){}

	public static function fromMinorUnits(int $minorUnits) : self{
		if($minorUnits < 0){
			throw new InvalidArgumentException("Currency cannot be negative, got $minorUnits minor units");
		}
		return new self($minorUnits);
	}
}

final class QueryFailure{
	public function __construct(private readonly string $message, private readonly ?int $sqlErrorCode = null){}
}

namespace RiftalGames\Contracts\Accounts;

use InvalidArgumentException;

final class AccountId{
	private function __construct(private readonly int $id){}

	public static function fromInt(int $id) : self{
		if($id < 1){
			throw new InvalidArgumentException("Account id must be a positive integer, got $id");
		}
		return new self($id);
	}
}

namespace RiftalGames\Contracts\Event;

use pocketmine\event\Event;
use RiftalGames\Contracts\InstanceIdentity;

abstract class RiftalEvent extends Event{
	public function __construct(private readonly InstanceIdentity $instance){}

	public function instance() : InstanceIdentity{
		return $this->instance;
	}
}

namespace RiftalGames\Contracts\Economy;

use Closure;
use InvalidArgumentException;
use RiftalGames\Contracts\Accounts\AccountId;
use RiftalGames\Contracts\Currency;
use RiftalGames\Contracts\Event\RiftalEvent;
use RiftalGames\Contracts\InstanceIdentity;
use RiftalGames\Contracts\QueryFailure;
use function preg_match;

enum CurrencyMovementReason : string{
	case Sale = "sale";
	case Refund = "refund";
	case RankUp = "rank_up";
	case GangCreation = "gang_creation";
	case GangContribution = "gang_contribution";
	case PlotExpansion = "plot_expansion";
}

final class RequestId{
	private function __construct(private readonly string $id){}

	public static function fromString(string $id) : self{
		if(preg_match('/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/', $id) !== 1){
			throw new InvalidArgumentException("Request id must be a lowercase canonical UUIDv7, got \"$id\"");
		}
		return new self($id);
	}

	public function toString() : string{
		return $this->id;
	}
}

final class CurrencyDebitRequestedEvent extends RiftalEvent{
	private readonly Closure $onDebited;
	private readonly Closure $onRejected;
	private readonly Closure $onFailed;
	private readonly ?Closure $onNotApplied;

	public function __construct(
		InstanceIdentity $instance,
		private readonly AccountId $accountId,
		private readonly Currency $amount,
		callable $onDebited,
		callable $onRejected,
		callable $onFailed,
		private readonly RequestId $requestId,
		private readonly CurrencyMovementReason $reason,
		?callable $onNotApplied = null
	){
		parent::__construct($instance);
		$this->onDebited = Closure::fromCallable($onDebited);
		$this->onRejected = Closure::fromCallable($onRejected);
		$this->onFailed = Closure::fromCallable($onFailed);
		$this->onNotApplied = $onNotApplied === null ? null : Closure::fromCallable($onNotApplied);
	}

	public function reason() : CurrencyMovementReason{
		return $this->reason;
	}

	public function debited() : void{
		($this->onDebited)();
	}

	public function rejected() : void{
		($this->onRejected)();
	}

	public function notApplied() : void{
		if($this->onNotApplied === null){
			$this->failed(new QueryFailure("Debit not applied"));
			return;
		}
		($this->onNotApplied)();
	}

	public function failed(QueryFailure $failure) : void{
		($this->onFailed)($failure);
	}
}
