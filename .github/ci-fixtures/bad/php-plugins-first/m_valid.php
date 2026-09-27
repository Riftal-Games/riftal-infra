<?php

// Expected: php -l reports no syntax errors. Untouched companion, present so
// the batch has a middle file that must still get its own php -l invocation
// after the broken first file.

declare(strict_types=1);

final class MValidFixture {
    public function ping(): string {
        return 'pong';
    }
}
