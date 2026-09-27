<?php

// Expected: php -l reports no syntax errors. Untouched companion, present so
// the batch has a last file that must still get its own php -l invocation
// after the broken middle file.

declare(strict_types=1);

final class ZValidFixture {
    public function ping(): string {
        return 'pong';
    }
}
