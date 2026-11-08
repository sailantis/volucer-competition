<?php

declare(strict_types=1);

/**
 * What would a compiled route table actually save?
 *
 * The measurement so far: registering 100 filler routes costs ~120 us of every
 * cold request (57.6% of a 208 us in-process boot, and 173 us of the 365 us of
 * framework CPU per request on the wire). It is not the filler routes' fault --
 * the marginal cost is a flat ~1.2 us per route whatever the table size -- it is
 * that a cold SAPI rebuilds the whole table from source on every request.
 *
 * That is a solved problem in most frameworks: Symfony's `route:cache` and
 * Laravel's `route:cache` both `var_export` the compiled table to a PHP file and
 * `require` it, so the per-request work becomes one opcache-served include instead
 * of N calls to `add()`. Azera has no equivalent.
 *
 * This measures what the equivalent would be worth, before proposing it: build
 * the real table once with the real router, serialize it, then time `require`ing
 * that back versus rebuilding it. If the saving is not large, the proposal is not
 * worth making.
 *
 * Usage: php scripts/probe-route-cache.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

function median(array $xs): float
{
    $n = count($xs);
    if ($n === 0) {
        return 0.0;
    }
    sort($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[$n / 2 - 1] + $xs[$n / 2]) / 2;
}

$dbPath = $root . '/data/bench.sqlite';
$tmp = sys_get_temp_dir() . '/bench-routecache.php';

// Build the real table with the real code. `profile()` left null so the boot
// runs exactly as it does in production.
\App\Azera\Bootstrap::forget();
$ctx = \App\Azera\Bootstrap::boot($dbPath);
$router = $ctx->router();

$ref = new ReflectionClass($router);
$state = [];
foreach (['static', 'groups', 'namedRoutes'] as $prop) {
    if (!$ref->hasProperty($prop)) {
        continue;
    }
    $p = $ref->getProperty($prop);
    $p->setAccessible(true);
    $state[$prop] = $p->getValue($router);
}

$routeCount = 0;
foreach ($state['static'] ?? [] as $byPath) {
    $routeCount += count($byPath);
}
foreach ($state['groups'] ?? [] as $byBucket) {
    foreach ($byBucket as $bucket) {
        $routeCount += count($bucket);
    }
}

echo 'Live table: ', $routeCount, " routes across ", count($state['static'] ?? []), " static method-maps and ",
    array_sum(array_map('count', $state['groups'] ?? [])), " dynamic buckets\n\n";

// Serialize the compiled state the way a `route:cache` command would.
file_put_contents($tmp, '<?php return ' . var_export($state, true) . ';');
printf("Compiled file: %.1f KB\n\n", filesize($tmp) / 1024);

// --- A. rebuild from source (what every cold request does today) -----------
$a = [];
for ($i = 0; $i < 300; $i++) {
    \App\Azera\Bootstrap::forget();
    $t = hrtime(true);
    \App\Azera\Bootstrap::boot($dbPath);
    $a[] = (hrtime(true) - $t) / 1000.0;
}

// --- B. hydrate the compiled table (what it would do instead) -------------
// `require` alone, then hand the arrays back to a fresh Router through the same
// properties. This is the honest lower bound: a real implementation would add a
// constructor that takes the state, and that is one more allocation.
$b = [];
for ($i = 0; $i < 300; $i++) {
    $t = hrtime(true);
    $loaded = require $tmp;
    $r = new \Azera\Core\Router();
    foreach ($loaded as $prop => $value) {
        $p = $ref->getProperty($prop);
        $p->setAccessible(true);
        $p->setValue($r, $value);
    }
    $b[] = (hrtime(true) - $t) / 1000.0;
}

// --- C. the floor: how long does the raw require take, with no router at all? --
$c = [];
for ($i = 0; $i < 300; $i++) {
    $t = hrtime(true);
    $loaded = require $tmp;
    $c[] = (hrtime(true) - $t) / 1000.0;
}

printf("A  rebuild from source   %8.1f us\n", median($a));
printf("B  require + hydrate     %8.1f us\n", median($b));
printf("C  require only          %8.1f us\n", median($c));
printf("\nsaving (A - B)           %8.1f us per cold request (%.0f%%)\n", median($a) - median($b), 100 * (median($a) - median($b)) / median($a));

// A compiled table must not change what the router answers.
$fresh = new \Azera\Core\Router();
foreach ((require $tmp) as $prop => $value) {
    $p = $ref->getProperty($prop);
    $p->setAccessible(true);
    $p->setValue($fresh, $value);
}
$probe = [
    ['/echo', 'GET'],
    ['/', 'GET'],
    ['/items', 'GET'],
    ['/items/7', 'GET'],
    ['/api/items', 'GET'],
    ['/api/v1/users/{p:int}', 'GET'],
    ['/blog/hello-world', 'GET'],
    ['/no-such-route', 'GET'],
];
$diffs = 0;
foreach ($probe as [$uri, $method]) {
    $x = \App\Azera\Bootstrap::boot($dbPath)->router()->match($uri, $method);
    $y = $fresh->match($uri, $method);
    if ($x != $y) {
        $diffs++;
        printf("MISMATCH %-24s\n  source: %s\n  cached: %s\n", $uri, var_export($x, true), var_export($y, true));
    }
}
echo $diffs === 0
    ? "\nEquivalence: all " . count($probe) . " probe routes match between source and compiled table\n"
    : "\nEquivalence FAILED ({$diffs} mismatches)\n";

@unlink($tmp);
