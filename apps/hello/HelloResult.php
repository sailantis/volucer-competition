<?php

declare(strict_types=1);

namespace App\Hello;

/**
 * One response, as a value.
 *
 * The three arms reach their server through three different response objects, and
 * this is the one thing the application itself produces. Keeping it a plain
 * readonly value rather than any server's own type is what lets `worker.php` and
 * `supervisor.php` share the application without either of them knowing about the
 * other.
 */
final class HelloResult
{
    /**
     * @param array<string, string> $headers
     */
    public function __construct(
        public readonly int $status,
        public readonly array $headers,
        public readonly string $body,
    ) {
    }
}
