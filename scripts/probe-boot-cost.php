<?php

declare(strict_types=1);

/**
 * What does Bootstrap::boot() actually cost on a cold request, and where does it go?
 *
 * `bare-echo.tsv` showed removing the framework lifts php-fpm from ~27,900 to
 * ~104,300 rps at c=96/w=32. That is a statement about a total, not a cause: the
 * boot is one block and every claim about *why* it is that size is a guess until
 * the block is split. This probes it.
 *
 * The measurement model is the cold arm's, not the warm arm's:
 *
 *   An fpm child forks from a master that has already started PHP, so the class
 *   autoloader and the opcode cache are warm from the child's first request on.
 *   Every later request still pays the full `boot()`, because a fresh
 *   `AppContext`, route table and service graph is built per request. So the
 *   number to explain is `boot()` at steady state in a live process -- which is
 *   `forget()` + `boot()` repeated, exactly as below.
 *
 * Usage:
 *   php scripts/probe-boot-cost.php              # full report
 *   php scripts/probe-boot-cost.php --routes     # filler-route scaling only
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';
require $root . '/BenchApp.php';

$dbPath = $root . '/data/bench.sqlite';
if (!is_file($dbPath)) {
    fwrite(STDERR, "missing {$dbPath}\n");
    exit(1);
}

$onlyRoutes = in_array('--routes', $argv, true);

/** Median: a per-request cost is dragged by GC and by first-touch faults, so the mean overstates it. */
function median(array $xs): float
{
    $n = count($xs);
    if ($n === 0) {
        return 0.0;
    }
    sort($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[$n / 2 - 1] + $xs[$n / 2]) / 2;
}

function line(array $xs): string
{
    $n = count($xs);
    sort($xs);
    return sprintf(
        'median %7.1f us    min %7.1f    p90 %7.1f    max %7.1f',
        median($xs),
        $xs[0],
        $xs[max(0, (int) floor($n * 0.9) - 1)],
        $xs[$n - 1],
    );
}

/** One cold boot, timed. */
function coldBoot(string $dbPath, int $fillers = 100): float
{
    \App\Azera\Bootstrap::forget();
    \App\Azera\Bootstrap::$fillerRoutes = $fillers;
    $t = hrtime(true);
    \App\Azera\Bootstrap::boot($dbPath);
    return (hrtime(true) - $t) / 1000.0;
}

// ---------------------------------------------------------------------------
// Filler-route scaling. Everything else is held constant, so the slope is the
// per-route cost of registering a route and the intercept is the rest of boot.
// ---------------------------------------------------------------------------

coldBoot($dbPath);

if ($onlyRoutes) {
    $counts = [0, 25, 50, 100, 200, 400];
    $rows = [];
    foreach ($counts as $n) {
        $s = [];
        for ($i = 0; $i < 300; $i++) {
            $s[] = coldBoot($dbPath, $n);
        }
        $rows[$n] = median($s);
    }
    echo "Filler-route scaling (cold boot, 300 samples each)\n";
    echo str_repeat('-', 68), "\n";
    printf("%-8s %14s %18s\n", 'routes', 'median us', 'marginal us/route');
    $prevN = null;
    foreach ($rows as $n => $us) {
        $marg = '-';
        if ($prevN !== null && $n > $prevN) {
            $marg = sprintf('%.3f', ($us - $rows[$prevN]) / ($n - $prevN));
        }
        printf("%-8d %14.1f %18s\n", $n, $us, $marg);
        $prevN = $n;
    }
    // The 100-route table is what every published number used, so its absolute
    // share is the number that matters even though the slope is the interesting one.
    printf(
        "\n100 filler routes cost %.1f us of a %.1f us boot (%.0f%%)\n",
        $rows[100] - $rows[0],
        $rows[100],
        100 * ($rows[100] - $rows[0]) / $rows[100],
    );
    exit(0);
}

// ---------------------------------------------------------------------------
// Phase breakdown.
// ---------------------------------------------------------------------------

$N = 300;

$samples = [];
$phases = [];
for ($i = 0; $i < $N; $i++) {
    \App\Azera\Bootstrap::forget();
    \App\Azera\Bootstrap::profile([]);
    $t = hrtime(true);
    \App\Azera\Bootstrap::boot($dbPath);
    $samples[] = (hrtime(true) - $t) / 1000.0;
    $p = \App\Azera\Bootstrap::$profile;
    \App\Azera\Bootstrap::profile(null);
    foreach ($p as $k => $v) {
        $phases[$k][] = $v;
    }
}

$filesBefore = count(get_included_files());

echo "Cold boot, {$N} samples\n";
echo str_repeat('=', 68), "\n";
echo '  total    ', line($samples), "\n\n";

echo "Phase breakdown (median us per boot)\n";
echo str_repeat('-', 68), "\n";
$mBoot = median($samples);
$sum = 0.0;
foreach ($phases as $label => $xs) {
    $m = median($xs);
    $sum += $m;
    printf("  %-28s %9.1f  %5.1f %%\n", $label, $m, 100 * $m / $mBoot);
}
printf("  %-28s %9.1f  %5.1f %%\n", 'unattributed', $mBoot - $sum, 100 * ($mBoot - $sum) / $mBoot);

// What a fresh fpm child pays once, before its first request is served.
echo "\nFirst boot in a live process (what a fresh fpm child pays once)\n";
echo str_repeat('-', 68), "\n";
\App\Azera\Bootstrap::forget();
$classesBeforeFirst = count(get_declared_classes(), COUNT_RECURSIVE);
$filesBeforeFirst = count(get_included_files());
$t = hrtime(true);
\App\Azera\Bootstrap::boot($dbPath);
$first = (hrtime(true) - $t) / 1000.0;
printf(
    "  %.1f us, +%d classes, +%d files\n",
    $first,
    count(get_declared_classes(), COUNT_RECURSIVE) - $classesBeforeFirst,
    count(get_included_files()) - $filesBeforeFirst,
);
printf("Steady-state boot has %d files included in total\n\n", count(get_included_files()) + 0 * $filesBefore);

// ---------------------------------------------------------------------------
// The other half of the cost: matching, once the table exists.
// ---------------------------------------------------------------------------

$matchEcho = [];
$matchFill = [];
$ctx = \App\Azera\Bootstrap::boot($dbPath);
$mk = static fn(string $uri) => new \Azera\Http\Request([
    'REQUEST_URI' => $uri,
    'REQUEST_METHOD' => 'GET',
    'SERVER_PROTOCOL' => 'HTTP/1.1',
    'HTTP_HOST' => 'bench.local',
    'SCRIPT_NAME' => '/index.php',
]);
$reqEcho = $mk('/echo');
$reqFill = $mk('/api/v1/Page/show');   // a filler route, so the walk is longer
for ($i = 0; $i < 2000; $i++) {
    $t0 = hrtime(true);
    $ctx->router()->match($reqEcho->path(), $reqEcho->method());
    $matchEcho[] = (hrtime(true) - $t0) / 1000.0;

    $t0 = hrtime(true);
    $ctx->router()->match($reqFill->path(), $reqFill->method());
    $matchFill[] = (hrtime(true) - $t0) / 1000.0;
}
echo "Route match (per request, not per boot)\n";
echo str_repeat('-', 68), "\n";
echo '  /echo              ', line($matchEcho), "\n";
echo '  filler route       ', line($matchFill), "\n\n";

// ---------------------------------------------------------------------------
// What a booted request costs, and what the cold arm's request costs in total.
// ---------------------------------------------------------------------------

$app = new BenchApp($dbPath);
$app->bootstrap();
$dispatch = ['/echo' => [], '/items' => [], '/api/items' => []];
foreach ($dispatch as $path => &$xs) {
    for ($i = 0; $i < 400; $i++) {
        $t = hrtime(true);
        $app->dispatch('GET', $path);
        $xs[] = (hrtime(true) - $t) / 1000.0;
        $app->cleanup();
    }
}
unset($xs);

echo "Warm dispatch (boot already paid)\n";
echo str_repeat('-', 68), "\n";
foreach ($dispatch as $path => $xs) {
    printf("  %-12s %s\n", $path, line($xs));
}

echo "\nOne request\n";
echo str_repeat('-', 68), "\n";
$mEcho = median($dispatch['/echo']);
printf("  cold arm (boot + dispatch)   %8.1f us   boot is %.0f%% of it\n", $mBoot + $mEcho, 100 * $mBoot / ($mBoot + $mEcho));
printf("  warm arm (dispatch only)     %8.1f us\n", $mEcho);
