<?php

declare(strict_types=1);

/**
 * Does insertion order change a route match, and does a `cached()` wrapper actually
 * skip the work?
 *
 * The proposal on the table is
 *
 *     $router->restoreIfCached($path);
 *     $router->cached(__FILE__, function (Router $r) { $r->add(...); ... });
 *
 * which uses `__FILE__` to declare the source instead of guessing it from a
 * backtrace. `__FILE__` inside the closure is the file the closure was *written* in,
 * so it is exact regardless of how many helper frames sit between `add()` and the
 * call, and an application physically cannot forget to declare a file because the
 * declaration is attached to the registering code.
 *
 * Two things decide whether that is safe, and neither can be settled by argument:
 *
 *   1. MIXED MODE. Routes registered outside any `cached()` block always execute.
 *      On a cache hit the cached block is restored first and the plain routes append
 *      afterwards, which is a different insertion order than a full build. If order
 *      affects matching, mixed mode is a correctness bug. The router defers its
 *      specificity sort, so order *should* not matter -- except on a tie, where
 *      `usort` stability decides, and PHP 8.0+ made `usort` stable. So ties are the
 *      risk, and ties are exactly what a route table with 100 filler routes has.
 *
 *   2. Does skipping the closure skip the cost? Obviously it skips the `add()` calls,
 *      but the wrapper has to be cheap itself.
 *
 * Usage: php scripts/probe-cached-blocks.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

use Azera\Core\Router;

function med(array $xs): float
{
    sort($xs);
    $n = count($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[intdiv($n, 2) - 1] + $xs[intdiv($n, 2)]) / 2;
}

// ---------------------------------------------------------------------------
// 1. Is __FILE__ inside a closure the declaring file?
// ---------------------------------------------------------------------------

$closure = static fn(): string => __FILE__;
printf("1. __FILE__ inside a closure -> %s\n", basename($closure()) === basename(__FILE__) ? 'correct' : 'WRONG');
printf("   ...and it is this probe: %s\n", $closure() === __FILE__ ? 'yes' : 'NO');

// Even through several layers of indirection, which is what broke the backtrace.
$factory = static fn(): Closure => static fn(): string => __FILE__;
$deep = $factory();
printf("   ...through a factory:    %s\n", $deep() === __FILE__ ? 'yes' : 'NO');

// ---------------------------------------------------------------------------
// 2. Does insertion order change a match when specificity ties?
// ---------------------------------------------------------------------------

echo "\n2. Insertion order and specificity ties\n";
echo str_repeat('-', 70), "\n";

// Two routes with the same shape and therefore the same specificity, differing only
// in their literal first segment. Both live in the same bucket only if that segment
// matches, so build a genuine tie: same pattern, different handler, added twice.
$orderA = new Router();
$orderA->get('/tie/{id:int}', 'First::handler');
$orderA->get('/tie/{id:int}', 'Second::handler');

$orderB = new Router();
$orderB->get('/tie/{id:int}', 'Second::handler');
$orderB->get('/tie/{id:int}', 'First::handler');

$mA = $orderA->match('/tie/7', 'GET');
$mB = $orderB->match('/tie/7', 'GET');
printf(
    "   exact duplicate, added A-then-B vs B-then-A: %s\n",
    ($mA['override']['action'] ?? '?') === ($mB['override']['action'] ?? '?') ? 'same winner' : 'DIFFERENT winner',
);

// A more realistic tie: /a/{x} and /a/{x} with different types that both score 4.
$tieA = new Router();
$tieA->get('/a/{x:alpha}', 'Alpha::handler');
$tieA->get('/a/{y:alnum}', 'Alnum::handler');

$tieB = new Router();
$tieB->get('/a/{x:alpha}', 'Alpha::handler');
$tieB->get('/a/{y:alnum}', 'Alnum::handler');

printf(
    "   different param types, same specificity: %s\n",
    json_encode($tieA->match('/a/abc', 'GET')) === json_encode($tieB->match('/a/abc', 'GET'))
        ? 'deterministic for identical build order'
        : 'nondeterministic',
);

// The real question: does the SAME set of routes built in two ORDERS match the same?
$build = static function (array $routes): Router {
    $r = new Router();
    foreach ($routes as [$pattern, $handler]) {
        $r->get($pattern, $handler);
    }
    return $r;
};

$routes = [
    ['/a/{x:alpha}', 'Alpha::handler'],
    ['/a/{y:alnum}', 'Alnum::handler'],
    ['/a/abc', 'Static::handler'],
];

$forward = $build($routes);
$reverse = $build(array_reverse($routes));

$probes = ['/a/abc', '/a/xyz', '/a/1'];
$diffs = 0;
foreach ($probes as $p) {
    $x = $forward->match($p, 'GET');
    $y = $reverse->match($p, 'GET');
    $same = json_encode($x['override'] ?? null) === json_encode($y['override'] ?? null);
    printf("   %-10s %s\n", $p, $same ? "same" : "DIFFERENT");
    if (!$same) {
        printf("      forward vars: %s\n", json_encode($x["vars"] ?? null));
        printf("      reverse vars: %s\n", json_encode($y["vars"] ?? null));
        printf("      forward ctrl: %s\n", json_encode($x["override"] ?? null));
        printf("      reverse ctrl: %s\n", json_encode($y["override"] ?? null));
    }
    if (!$same) {
        $diffs++;
    }
}
printf(
    "\n   %s\n",
    $diffs === 0
        ? 'Order does NOT affect matching for this set: mixed mode is safe here.'
        : "Order DOES affect matching ({$diffs} of " . count($probes) . ' probes): mixed mode is a correctness risk.',
);

// ---------------------------------------------------------------------------
// 3. Does a cached() wrapper actually skip the registration cost?
// ---------------------------------------------------------------------------

echo "\n3. Cost of the wrapper itself\n";
echo str_repeat('-', 70), "\n";

/** Stand-in for Router::cached(): record the source, then run (or skip) the block. */
final class Cached
{
    /** @var array<string,true> */
    public array $sources = [];
    public bool $skip = false;

    public function cached(string $source, callable $register): void
    {
        $this->sources[$source] = true;
        if ($this->skip) {
            return;
        }
        $register($this);
    }
}

$work = static function (Cached $r): void {
    for ($i = 0; $i < 120; $i++) {
        $r->sources["f{$i}"] = true;
    }
};

$run = [];
$c = new Cached();
for ($i = 0; $i < 500; $i++) {
    $c->sources = [];
    $c->skip = false;
    $t = hrtime(true);
    $c->cached(__FILE__, $work);
    $run[] = (hrtime(true) - $t) / 1000.0;
}

$skipped = [];
for ($i = 0; $i < 500; $i++) {
    $c->sources = [];
    $c->skip = true;
    $t = hrtime(true);
    $c->cached(__FILE__, $work);
    $skipped[] = (hrtime(true) - $t) / 1000.0;
}

printf("   block runs (120 registrations): %6.1f us\n", med($run));
printf("   block skipped:                  %6.1f us\n", med($skipped));
printf("   the wrapper itself costs:       %6.3f us\n", med($skipped));

// The full-build-vs-restore comparison lives in probe-route-encodings.php, which
// measures it across two processes. Doing it inline here measured a fresh compile
// (the file had just been written) and produced 517 us, which is the
// file_update_protection trap again -- left out rather than kept with a disclaimer.
