<?php

// Expected: php -l reports no syntax errors. Alphabetically first of three
// files in this directory, so the batch has something to check before the
// file that carries the interesting position in the bad fixtures.

declare(strict_types=1);

final class AValidFixture {
    public function ping(): string {
        return 'pong';
    }
}
