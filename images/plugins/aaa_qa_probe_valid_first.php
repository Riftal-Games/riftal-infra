<?php

declare(strict_types=1);

// QA probe fixture for pmmp-infra#112 / PR #116 re-verification.
// Sorts before the broken fixture so a lint invocation that only
// checks its first argument would report success despite the
// syntax error in the middle file.
final class QaProbeValidFirst {
    public function ping(): string {
        return "pong";
    }
}
