<?php

// Expected: php -l fails on this file. Alphabetically the middle of three,
// the position a find -exec {} + batched invocation was mistakenly believed
// to skip in favour of only the first argument. It does not skip it, but the
// belief cost this check two implementation rounds, so the position stays
// covered.

declare(strict_types=1);

final class MBrokenFixture {
    public function ping(): string {
        return 'pong';
