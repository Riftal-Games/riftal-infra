<?php

// Expected: php -l fails on this file. Alphabetically last of three, the one
// position a bare "$?" of the loop's final command reports correctly on its
// own, and also the position a bare `find -exec cmd {} \;` swallows just like
// every other position, since find's own exit status never reflects a
// per-match invocation's result regardless of where the match falls.

declare(strict_types=1);

final class ZBrokenFixture {
    public function ping(): string {
        return 'pong';
