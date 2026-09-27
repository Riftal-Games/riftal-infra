<?php

// Expected: php -l reports no syntax errors. Alphabetically last of three
// files in this directory, the position a bare shell loop with no exit-status
// accumulator would report on regardless of what the other two files did.

declare(strict_types=1);

final class ZValidFixture {
    public function ping(): string {
        return 'pong';
    }
}
