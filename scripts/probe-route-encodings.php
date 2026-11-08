<?php

declare(strict_types=1);

/**
 * How cheaply can a precompiled route table actually be loaded?
 *
 * `probe-route-cache.php` concluded that a route cache does not help, because
 * `require`ing a `var_export`ed table cost 436 us against 108 us to rebuild from
 * source. **That conclusion was wrong, and the reason is worth recording**: the
 * probe wrote the cache file and required it in the same PHP process, and OPcache
 * declines to cache a file that the same process just wrote. So the "cached" arm
 * recompiled 61 KB of PHP on every iteration and was really measuring
 * `zend_compile`, not file loading. The assertion below exists so that cannot
 * happen silently again.
 *
 * The fix is the honest shape anyway: a route cache is produced by a deploy step,
 * never by the request that uses it. So this probe runs in two processes.
 *
 *   --generate     write the encoded files, then exit       (the deploy step)
 *   (default)      load them and time it                    (the request)
 *
 * Usage:
 *   PHP_INI_SCAN_DIR=/home/competition/jit-on \
 *   php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \
 *     scripts/probe-route-encodings.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

$db = $root . '/data/bench.sqlite';
$dir = sys_get_temp_dir() . '/route-enc';
$generate = in_array('--generate', $argv, true);

function med(array $xs): float
{
    sort($xs);
    $n = count($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[$n / 2 - 1] + $xs[$n / 2]) / 2;
}

function bench(callable $fn, int $n = 200): float
{
    $fn(-1);                       // warm, so first-touch faults are not the median
    $s = [];
    for ($i = 0; $i < $n; $i++) {
        $t = hrtime(true);
        $fn($i);
        $s[] = (hrtime(true) - $t) / 1000.0;
    }
    return med($s);
}

/** The live table, as the running router holds it. */
function liveState(string $db): array
{
    \App\Azera\Bootstrap::forget();
    $router = \App\Azera\Bootstrap::boot($db)->router();
    $ref = new ReflectionClass($router);
    $state = [];
    // `unsortedBuckets` is included deliberately. It is the deferred-sort
    // bookkeeping: if it is restored as "these buckets are dirty", the first
    // match pays a usort that the source path would also pay, so leaving it out
    // would flatter the cache. Capturing it from a booted-but-never-matched
    // router keeps the two arms identical.
    foreach (['static', 'groups', 'namedRoutes', 'unsortedBuckets'] as $p) {
        if (!$ref->hasProperty($p)) {
            continue;
        }
        $rp = $ref->getProperty($p);
        $rp->setAccessible(true);
        $state[$p] = $rp->getValue($router);
    }
    return $state;
}

$files = [
    'var_export' => $dir . '/routes.php',
    'serialize' => $dir . '/routes.ser',
    'igbinary' => $dir . '/routes.ig',
    'json' => $dir . '/routes.json',
    'floor' => $dir . '/floor.php',
];

// ---------------------------------------------------------------------------
// Deploy step.
// ---------------------------------------------------------------------------

if ($generate) {
    @mkdir($dir, 0777, true);
    foreach (glob($dir . '/*') as $f) {
        @unlink($f);
    }
    $state = liveState($db);
    // Keep the fixture minimal: the benchmark's own classes, nothing from this
    // probe, so the file's opcodes are the table and not our scaffolding.
    file_put_contents($files['var_export'], '<?php return ' . var_export($state, true) . ';');
    file_put_contents($files['serialize'], serialize($state));
    if (function_exists('igbinary_serialize')) {
        file_put_contents($files['igbinary'], igbinary_serialize($state));
    }
    file_put_contents($files['json'], json_encode($state, JSON_THROW_ON_ERROR));
    file_put_contents($files['floor'], "<?php\nreturn ['x' => 1];\n");
    echo "generated in {$dir}\n";
    exit(0);
}

if (!is_file($files['var_export'])) {
    fwrite(STDERR, "run with --generate first\n");
    exit(1);
}

// ---------------------------------------------------------------------------
// Request step. Nothing below creates a file.
// ---------------------------------------------------------------------------

$state = liveState($db);
$router = \App\Azera\Bootstrap::boot($db)->router();
$ref = new ReflectionClass($router);

$routes = 0;
foreach ($state['static'] as $byPath) {
    $routes += count($byPath);
}
foreach ($state['groups'] as $bucket) {
    foreach ($bucket as $list) {
        $routes += count($list);
    }
}

$opcacheOn = function_exists('opcache_get_status')
    && (opcache_get_status(false)['opcache_enabled'] ?? false);

printf(
    "table: %d routes, opcache_cli=%s, igbinary=%s\n\n",
    $routes,
    $opcacheOn ? 'ON' : 'OFF',
    extension_loaded('igbinary') ? 'yes' : 'no',
);

echo "Encoded size\n";
echo str_repeat('-', 40), "\n";
foreach ($files as $k => $f) {
    printf("  %-12s %8.1f KB\n", $k, is_file($f) ? filesize($f) / 1024 : 0.0);
}

// The assertion the old probe lacked. If the PHP files are not cached, the rows
// below measure compilation and the whole report is worthless, so fail rather
// than tabulate a wrong number.
if ($opcacheOn) {
    require $files['floor'];
    require $files['var_export'];
    foreach (['floor', 'var_export'] as $k) {
        if (!opcache_is_script_cached($files[$k])) {
            fwrite(
                STDERR,
                "\nFAIL: {$files[$k]} is not in opcache, so this run would measure\n"
                . "compilation. Generate and measure in separate processes and make\n"
                . "sure opcache.file_update_protection has elapsed between them.\n",
            );
            exit(1);
        }
    }
    echo "\n  (both PHP files confirmed in opcache)\n";
}

$hydrate = static function (array $loaded) use ($ref) {
    $r = new \Azera\Core\Router();
    foreach ($loaded as $p => $v) {
        $rp = $ref->getProperty($p);
        $rp->setAccessible(true);
        $rp->setValue($r, $v);
    }
    return $r;
};

$load = [];

$load['floor (trivial require)'] = bench(static fn() => require $files['floor']);
$load['var_export + require'] = bench(static fn() => require $files['var_export']);
$load['unserialize()'] = bench(static fn() => unserialize(file_get_contents($files['serialize'])));

if (is_file($files['igbinary'])) {
    $load['igbinary_unserialize()'] = bench(
        static fn() => igbinary_unserialize(file_get_contents($files['igbinary'])),
    );
}

$load['json_decode()'] = bench(static fn() => json_decode(file_get_contents($files['json']), true));
$load['var_export + hydrate'] = bench(static fn() => $hydrate(require $files['var_export']));
$load['unserialize + hydrate'] = bench(
    static fn() => $hydrate(unserialize(file_get_contents($files['serialize']))),
);

if (is_file($files['igbinary'])) {
    $load['igbinary + hydrate'] = bench(
        static fn() => $hydrate(igbinary_unserialize(file_get_contents($files['igbinary']))),
    );
}

// Rebuilding from source, for the comparison a cache is supposed to win.
$load['rebuild from source'] = bench(static function () use ($db) {
    \App\Azera\Bootstrap::forget();
    \App\Azera\Bootstrap::boot($db);
}, 100);

// The theoretical floor for any cache: arrays that already exist, assigned onto a
// fresh Router. No parsing, no specificity, no pattern hashing, no decoding.
$load['build-direct (no add())'] = bench(static fn() => $hydrate($state));

// Match latency must not regress: a cache that makes boot cheap and matching slow
// has moved the cost, not removed it.
$match = bench(static function () use ($router) {
    $router->match('/echo', 'GET');
}, 4000);

echo "\nTime to produce a usable Router (median)\n";
echo str_repeat('-', 56), "\n";
$source = $load['rebuild from source'];
foreach ($load as $label => $us) {
    $vs = $label === 'rebuild from source'
        ? ''
        : sprintf('  %+5.0f%% vs source', 100 * ($us - $source) / $source);
    printf("  %-26s %8.1f us%s\n", $label, $us, $vs);
}
printf("\n  match /echo, after loading   %8.3f us   (must not regress)\n", $match);

if ($opcacheOn) {
    $st = opcache_get_status(false);
    printf(
        "\n  opcache: %d scripts, %.1f MB used, hits %d, misses %d\n",
        $st['opcache_statistics']['num_cached_scripts'] ?? -1,
        ($st['memory_usage']['used_memory'] ?? 0) / 1048576,
        $st['opcache_statistics']['hits'] ?? -1,
        $st['opcache_statistics']['misses'] ?? -1,
    );
}

// Equivalence: a cache that changes the answer is not a cache.
$cachedRouter = $hydrate(require $files['var_export']);
$diffs = 0;
foreach ([['/echo', 'GET'], ['/', 'GET'], ['/items', 'GET'], ['/items/7', 'GET'],
          ['/api/items', 'GET'], ['/blog/hello-world', 'GET'], ['/nope', 'GET']] as [$uri, $m]) {
    if ($router->match($uri, $m) != $cachedRouter->match($uri, $m)) {
        $diffs++;
        echo "MISMATCH {$uri}\n";
    }
}
echo $diffs === 0
    ? "\nEquivalence: serialized table matches the live one on all 7 probe routes\n"
    : "\nEquivalence FAILED ({$diffs})\n";
