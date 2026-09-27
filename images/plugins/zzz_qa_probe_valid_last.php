<?php

declare(strict_types=1);

// QA probe fixture for pmmp-infra#112 / PR #116 re-verification.
// Sorts after the broken fixture, mirroring the original bug's
// last-file case so this probe also re-confirms that regression
// stays fixed.
final class QaProbeValidLast {
    public function ping(): string {
        return "pong";
    }
}
