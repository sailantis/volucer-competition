<?php

declare(strict_types=1);

/**
 * Does a class static survive between requests in a persistent SAPI?
 *
 * `Bootstrap::$wired` is a static memo whose documented purpose is to let a
 * "worker-mode re-bootstrap" skip rebuilding the container and the ~120-entry
 * route table. `probe-phases.sh` measures 211 us of `bootstrap()` per framed
 * request in php-fpm, which is the cost of a *cold* boot -- so either the memo is
 * not being hit, or the hit is expensive.
 *
 * There is a real reason to suspect it is never hit. PHP resets mutable class
 * statics to their declared defaults at request startup and restores them at
 * request shutdown, because with opcache the class entry lives in shared memory
 * and mutable state must not leak between requests. If that applies here, the
 * memo is dead code on every SAPI that reuses a process across requests -- and
 * the code comment claiming it saves 0.38 ms per warm recycle is wrong.
 *
 * This answers it from inside a live fpm child rather than from the manual.
 *
 * Usage: served by probe-static.sh, which appends one line per request.
 */

declare(strict_types=1);

final class StaticProbe
{
    public static int $counter = 0;
    public static array $store = [];
    /** @var array<string,int> */
    public static array $seen = [];
}

StaticProbe::$counter++;
StaticProbe::$store[] = getmypid();

$out = getenv('BENCH_STATIC_LOG');
if ($out !== false && $out !== '') {
    @file_put_contents(
        $out,
        sprintf("%d\t%d\t%d\t%d\n", getmypid(), StaticProbe::$counter, count(StaticProbe::$store), memory_get_usage()),
        FILE_APPEND,
    );
}

header('Content-Type: text/plain');
echo StaticProbe::$counter;
