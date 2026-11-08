<?php

declare(strict_types=1);

/**
 * Where does the per-request CPU actually go, inside a live FPM child?
 *
 * `probe-boot-profile.sh` measured 426.5 us of server CPU per framed `/echo`
 * request against 71.0 us bare -- 355.5 us that bare does not pay. But
 * `probe-boot-cost.php` measures a *cold* `Bootstrap::boot()` at only ~152 us,
 * and in a resident FPM child `Bootstrap::$wired` is memoised, so from the
 * child's second request on `boot()` returns immediately. The two numbers cannot
 * both be describing the same request, and guessing which one is wrong is how a
 * benchmark stops being one.
 *
 * So this entry point is `public/index.php` with a timer on every phase. It is
 * byte-for-byte the same work -- same require, same BenchApp, same dispatch,
 * same echo -- and it appends one line per request to $BENCH_PHASES. Run it
 * single-child, read the file, median the columns.
 *
 * The phase timers are `hrtime(true)`, which on x86-64 is `clock_gettime`, i.e.
 * a vDSO call: ~20-25 ns each, so about 0.15 us for the whole set against a
 * ~400 us request. It does not perturb what it measures.
 *
 * Usage (from probe-phases.sh, which sets the environment):
 *   BENCH_PHASES=/tmp/x.tsv BENCH_BARE=0 php-fpm ... -S .../probe-phases.php
 */

declare(strict_types=1);

$T = static fn(): int => hrtime(true);
$marks = [];
$t = $T();

$root = dirname(__DIR__);
$dbPath = $root . '/data/bench.sqlite';
$bare = getenv('BENCH_BARE') === '1';

if (!$bare && !file_exists($dbPath)) {
    http_response_code(500);
    echo 'Database not found. Run: php seed.php';
    exit;
}

require $root . '/vendor/autoload.php';
$marks['autoload'] = $T() - $t;
$t = $T();

require $root . '/BenchApp.php';
$marks['benchapp'] = $T() - $t;
$t = $T();

// Vary the filler-route count without touching the app: `Bootstrap::boot()` reads
// the static, and PHP resets statics between requests, so setting it here is the
// same as setting it anywhere.
if (($f = getenv('BENCH_FILLERS')) !== false && $f !== '') {
    \App\Azera\Bootstrap::$fillerRoutes = (int) $f;
}

$app = new BenchApp($dbPath, $bare);
$marks['construct'] = $T() - $t;
$t = $T();

// Per-phase timings from inside the framework, so a 211 us `bootstrap` becomes
// a list of named contributors instead of one opaque block.
if (getenv('BENCH_PHASE_PROFILE') === '1') {
    \App\Azera\Bootstrap::profile([]);
}

$app->bootstrap();
$marks['bootstrap'] = $T() - $t;
$t = $T();

$phaseDetail = \App\Azera\Bootstrap::$profile ?? [];

$result = $app->dispatch(
    $_SERVER['REQUEST_METHOD'] ?? 'GET',
    $_SERVER['REQUEST_URI'] ?? '/',
);
$marks['dispatch'] = $T() - $t;
$t = $T();

$app->cleanup();

http_response_code($result->status);
header('Content-Type: text/html; charset=utf-8');
echo $result->body;
$marks['respond'] = $T() - $t;

// One line per request, appended. Under concurrency this interleaves; the
// probe runs a single child precisely so it cannot.
$out = getenv('BENCH_PHASES');
if ($out !== false && $out !== '') {
    $line = sprintf(
        "%s\t%d\t%d\t%d\t%d\t%d\t%d",
        $bare ? 'bare' : 'framed',
        $marks['autoload'],
        $marks['benchapp'],
        $marks['construct'],
        $marks['bootstrap'],
        $marks['dispatch'],
        $marks['respond'],
    );
    // The per-phase detail rides on the same line, tab-separated after the
    // fixed columns, so both views come from one request and cannot disagree.
    foreach ($phaseDetail as $k => $v) {
        $line .= sprintf("\t%s=%d", $k, (int) round($v * 1000));
    }
    @file_put_contents($out, $line . "\n", FILE_APPEND);
}
