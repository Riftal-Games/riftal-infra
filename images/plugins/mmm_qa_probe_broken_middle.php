<?php

declare(strict_types=1);

// QA probe fixture for pmmp-infra#112 / PR #116 re-verification.
// Deliberately unparseable, and named to sort in the middle of the
// three probe files so neither a first-argument-only nor a
// last-argument-only lint invocation would happen to catch it by
// accident.
final class QaProbeBrokenMiddle {
    public function ping(): string {
        return "pong"
    }
