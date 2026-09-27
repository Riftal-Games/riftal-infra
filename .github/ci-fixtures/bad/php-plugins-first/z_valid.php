<?php

// Expected: php -l reports no syntax errors. Untouched companion, present so
// the batch has a last file that must still get its own php -l invocation and
// must not be mistaken by the runner for the whole batch's exit status.

declare(strict_types=1);

final class ZValidFixture {
    public function ping(): string {
        return 'pong';
    }
}
