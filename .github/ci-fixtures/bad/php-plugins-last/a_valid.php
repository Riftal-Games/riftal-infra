<?php

// Expected: php -l reports no syntax errors. Untouched companion, present so
// the batch has a first file that must still get its own php -l invocation
// before the broken last file.

declare(strict_types=1);

final class AValidFixture {
    public function ping(): string {
        return 'pong';
    }
}
