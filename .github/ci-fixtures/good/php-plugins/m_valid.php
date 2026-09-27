<?php

// Expected: php -l reports no syntax errors. Alphabetically the middle file
// of three in this directory.

declare(strict_types=1);

final class MValidFixture {
    public function ping(): string {
        return 'pong';
    }
}
