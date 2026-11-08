<?php

declare(strict_types=1);

/**
 * Can the router remember which PHP files registered its routes?
 *
 * This is the question behind the Symfony-style staleness check: Symfony
 * regenerates when a *resource* file is newer than the compiled cache, and its
 * resources are known because routing is declared in config. Azera's routes come
 * from arbitrary PHP inside `registerRoutes()`, so the resource list has to be
 * discovered -- and `debug_backtrace()` at registration time can discover it.
 *
 * Before relying on that, three things have to be true, and each is checked here:
 *
 *   1. The frame that called `add()` is visible from inside `add()`.
 *   2. Repeated registration records each file once, not once per route.
 *   3. The cost is small enough to pay 120 times during a boot (and, more
 *      importantly, ~zero during a *restored* boot, which registers nothing).
 *
 * Usage: php scripts/probe-route-sources.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

function med(array $xs): float
{
    sort($xs);
    $n = count($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[$n / 2 - 1] + $xs[$n / 2]) / 2;
}

/**
 * A minimal stand-in for the router method, so the backtrace shape can be studied
 * without touching the framework.
 *
 * `debug_backtrace()` frame 0 is the *current* call, and its `file` is where that
 * call was made -- so a direct caller is frame 0, not frame 1. When `get()` calls
 * `add()`, the useful frame is the one *outside this class*, which is why the
 * lookup filters by class rather than counting frames. An earlier version of this
 * probe hard-coded frame 1 and recorded nothing, which would have been a wrong
 * answer stated confidently.
 */
final class Probe
{
    /** @var array<string,true> */
    public array $sources = [];

    public function record(): void
    {
        $this->sources[$this->callerFile()] = true;
    }

    /** A second entry point, to check that the lookup survives an extra frame. */
    public function get(string $path): void
    {
        $this->record();
    }

    /**
     * The file that called into the router.
     *
     * `debug_backtrace()` frame 0 carries the file and line *where the current
     * function was called from*, so frame 0 is already the call site. The frames
     * that belong to this class are skipped so that `get() -> add()` reports the
     * application's file rather than `get()`; when every frame is internal (called
     * straight from global scope) the outermost file is the right answer and the
     * loop falls back to it.
     *
     * Two earlier versions of this got it wrong and silently recorded nothing --
     * first because they hard-coded frame 1, then because they skipped every frame
     * and had no fallback. A freshness check that records no files would report
     * "fresh" forever, so this fallback is the difference between a working check
     * and one that never fires.
     */
    private function callerFile(): string
    {
        $trace = debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS, 8);

        $outermost = '';
        foreach ($trace as $frame) {
            if (!isset($frame['file'])) {
                continue;
            }
            $outermost = $frame['file'];
            if (($frame['class'] ?? null) !== self::class) {
                return $frame['file'];
            }
        }

        return $outermost;
    }
}

// --- 1. Is the caller visible? -------------------------------------------
$p = new Probe();
$p->record();
printf("1. caller recorded:   %s\n", $p->sources === [] ? 'NO' : array_key_first($p->sources));

// --- 2. Deduplication -----------------------------------------------------
$p = new Probe();
for ($i = 0; $i < 120; $i++) {
    $p->record();
}
printf("2. 120 registrations -> %d distinct source file(s)\n", count($p->sources));

$p2 = new Probe();
$p2->get('/a');
printf(
    "   via a second entry point (get -> record): %s\n",
    $p2->sources === [] ? 'NO' : basename(array_key_first($p2->sources)),
);

// --- 3. Cost -------------------------------------------------------------
$p = new Probe();
$cost = [];
$N = 2000;
for ($i = 0; $i < $N; $i++) {
    $t = hrtime(true);
    $p->record();
    $cost[] = (hrtime(true) - $t) / 1000.0;
}
printf("3. per registration:  %.3f us  (x120 routes = %.1f us)\n", med($cost), med($cost) * 120);

// And what the same budget looks like with the cheap alternative: nothing.
$cost2 = [];
$sink = [];
for ($i = 0; $i < $N; $i++) {
    $t = hrtime(true);
    $sink[] = __FILE__;
    $cost2[] = (hrtime(true) - $t) / 1000.0;
}
printf("   for comparison, a bare append: %.3f us\n", med($cost2));

// --- 4. Does it find the real thing in the real app? ---------------------
echo "\n4. real application bootstrap\n";
\App\Azera\Bootstrap::forget();
$start = hrtime(true);
$ctx = \App\Azera\Bootstrap::boot($root . '/data/bench.sqlite');
$boot = (hrtime(true) - $start) / 1000.0;

// The files that *define* the routes, which is what a cache would stat.
$candidates = [
    $root . '/apps/azera/Bootstrap.php',
    $root . '/apps/azera/Controllers/BenchController.php',
];
foreach ($candidates as $c) {
    printf("   %-58s exists=%s mtime=%d\n", basename($c), is_file($c) ? 'yes' : 'NO', is_file($c) ? filemtime($c) : 0);
}

// A directory-level mtime is the cheap conservative alternative: any edit inside
// the routes directory bumps it, without needing a per-file list at all.
$dir = $root . '/apps/azera';
clearstatcache(true, $dir);
printf("   %-58s mtime=%d\n", 'apps/azera/ (directory)', filemtime($dir));
printf("   boot: %.1f us\n", $boot);

// --- 5. How expensive is the freshness check itself? ---------------------
echo "\n5. cost of a freshness check\n";
$files = [$root . '/apps/azera/Bootstrap.php', $root . '/apps/azera/Controllers/BenchController.php'];
$perFile = [];
for ($i = 0; $i < 2000; $i++) {
    $t = hrtime(true);
    clearstatcache(true, $files[0]);
    filemtime($files[0]);
    $perFile[] = (hrtime(true) - $t) / 1000.0;
}
$perDir = [];
for ($i = 0; $i < 2000; $i++) {
    $t = hrtime(true);
    clearstatcache(true, $dir);
    filemtime($dir);
    $perDir[] = (hrtime(true) - $t) / 1000.0;
}
printf("   stat one file:              %.3f us\n", med($perFile));
printf("   stat the routes directory:  %.3f us\n", med($perDir));

// Without the clearstatcache the second call is free -- PHP caches stat results --
// which is the trap: a naive check would pass on the first request and then be
// skipped forever, so the cache would never notice an edit. Worth stating.
$noClear = [];
for ($i = 0; $i < 2000; $i++) {
    $t = hrtime(true);
    filemtime($files[0]);
    $noClear[] = (hrtime(true) - $t) / 1000.0;
}
printf("   without clearstatcache:     %.3f us  (PHP's stat cache answers it)\n", med($noClear));
