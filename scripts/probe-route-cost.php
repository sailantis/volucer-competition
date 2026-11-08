<?php

declare(strict_types=1);

/**
 * Where does the ~1.2 us per registered route go?
 *
 * `probe-boot-cost.php --routes` showed registration costs a flat ~1.2 us per
 * route at every table size, which means the 100 filler routes are not expensive
 * because the table is big -- they are expensive because *each* route is. This
 * splits that per-route cost into its parts.
 *
 * The candidate operations, in the order `Router::add()` performs them:
 *
 *   parsePattern()    explode + per-segment token classification
 *   storeRoute()      hash insert, or append + specificity + deferred-sort flag
 *   sortBucket()      a usort of the whole bucket, paid once per bucket on the
 *                     first match that reads it -- not per insert, but it is
 *                     real and it is O(n log n) per bucket
 *
 * Everything is measured against the real Router class, not a copy of the code,
 * so a change in the framework shows up here.
 *
 * Usage: php scripts/probe-route-cost.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

function median(array $xs): float
{
    sort($xs);
    $n = count($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[$n / 2 - 1] + $xs[$n / 2]) / 2;
}

/** Run $fn $n times and return the median per-iteration microseconds. */
function per(callable $fn, int $n = 2000): float
{
    $s = [];
    for ($i = 0; $i < $n; $i++) {
        $t = hrtime(true);
        $fn($i);
        $s[] = (hrtime(true) - $t) / 1000.0;
    }
    return median($s);
}

$cls = \Azera\Core\Router::class;

// --- 1. parsePattern(): reflection, because it is protected ----------------
$router = new $cls();
$parse = new ReflectionMethod($cls, 'parsePattern');
$patterns = [
    'static'        => '/admin/users/index',
    'param'         => '/api/v1/users/{param1:int}',
    'nested'        => '/api/v1/users/{param1:int}/posts/{post1:int}',
    'slug'          => '/blog/hello-world',
    'wildcard'      => '/assets/user/{file1:*}',
];
echo "parsePattern() per call\n";
echo str_repeat('-', 60), "\n";
foreach ($patterns as $label => $p) {
    printf("  %-10s %6.3f us\n", $label, per(fn() => $parse->invoke($router, $p)));
}

// --- 2. A full add(), by shape --------------------------------------------
echo "\nRouter::add() per route, into an empty router each time\n";
echo str_repeat('-', 60), "\n";
foreach ($patterns as $label => $p) {
    $method = 'add';
    printf(
        "  %-10s %6.3f us\n",
        $label,
        per(function () use ($cls, $p) {
            $r = new $cls();
            $r->add(['GET', 'POST'], $p);
        }),
    );
}

// --- 3. Marginal cost of the Nth route into the SAME router ---------------
// The slope from probe-boot-cost. Measured in place so nothing but the insert
// differs: no fresh Router, no re-warm.
echo "\nMarginal add() into a live router (measured in place)\n";
echo str_repeat('-', 60), "\n";
$r = new $cls();
$marks = [0, 25, 50, 100, 200];
$samples = [];
for ($i = 0; $i < 400; $i++) {
    $t = hrtime(true);
    $r->get("/blog/hello-world-{$i}");
    $samples[$i] = (hrtime(true) - $t) / 1000.0;
}
foreach ($marks as $m) {
    $slice = array_slice($samples, $m, 25, true);
    printf("  routes %3d-%3d  %6.3f us\n", $m, $m + 24, median($slice));
}

// --- 4. The deferred sort, paid on the first match ------------------------
echo "\nBucket sort (deferred to the first match that reads it)\n";
echo str_repeat('-', 60), "\n";
$r = new $cls();
for ($i = 1; $i <= 200; $i++) {
    $r->get("/blog/slug-{$i}");
}
$t = hrtime(true);
$r->match('/blog/slug-100', 'GET');
$sortOnce = (hrtime(true) - $t) / 1000.0;
$t = hrtime(true);
$r->match('/blog/slug-100', 'GET');
$matchAfter = (hrtime(true) - $t) / 1000.0;
printf("  first match (sorts 200)  %6.1f us\n", $sortOnce);
printf("  next match  (sorted)     %6.2f us\n", $matchAfter);

// --- 5. What 100 filler routes cost a match, amortised --------------------
echo "\nMatch cost against table size (median per match)\n";
echo str_repeat('-', 60), "\n";
foreach ([0, 100, 400] as $fillers) {
    $r = new $cls();
    $r->get('/echo');
    for ($i = 1; $i <= $fillers; $i++) {
        $r->get("/blog/slug-{$i}");
        $r->get("/api/v1/Page/{p{$i}:int}");
    }
    $r->match('/echo', 'GET');           // force the sort, so this is the steady state
    printf("  %4d filler routes   /echo %6.3f us\n", $fillers, per(fn() => $r->match('/echo', 'GET'), 4000));
}
