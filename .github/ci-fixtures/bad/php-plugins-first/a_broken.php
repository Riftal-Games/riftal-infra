<?php

// Expected: php -l fails on this file. Alphabetically first of three, the
// exact position a bare shell loop with no exit-status accumulator swallows:
// its own exit code is the *last* command's, so an error here goes unreported
// unless every file's exit status is captured on its own line.

declare(strict_types=1);

final class ABrokenFixture {
    public function ping(): string {
        return 'pong';
    }
