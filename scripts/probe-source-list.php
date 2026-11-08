<?php

declare(strict_types=1);

/**
 * How would an explicitly-declared source list work, and what does it cost?
 *
 * `probe-backtrace-cost.php` showed that `debug_backtrace()` can find the file that
 * registered a route. It is the wrong foundation anyway: a helper, a loop over a
 * config array, a factory returning a closure -- any of them puts a frame between
 * `add()` and the file that really declares the routes, and the backtrace records
 * the wrapper instead. That failure is silent and records a *plausible* file, so the
 * cache would look healthy and never invalidate. Fragile in the one direction that
 * matters.
 *
 * Symfony avoids this by not observing: the Router is handed a `$resource`
 * (a path or glob) and records it. The source list is declared, not inferred.
 *
 * This probe checks the two things that would make the same approach work here:
 *
 *   A. What does N stats cost? (the whole runtime invalidation check)
 *   B. Which filesystem events bump a DIRECTORY's mtime, and which do not?
 *      A directory mtime catches additions, deletions and renames but NOT edits to
 *      a file already in it -- so a directory alone is not sufficient, and a file
 *      list alone misses new files. Both are needed, and the cost of both is small.
 *
 * Usage: php scripts/probe-source-list.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

function med(array $xs): float
{
    sort($xs);
    $n = count($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[intdiv($n, 2) - 1] + $xs[intdiv($n, 2)]) / 2;
}

/** Honest stat: clear first, or PHP answers from its stat cache and the cost is a lie. */
function statOf(string $path): array
{
    clearstatcache(true, $path);
    $t = hrtime(true);
    $m = @filemtime($path);
    $us = (hrtime(true) - $t) / 1000.0;
    return [$m, $us];
}

$dir = sys_get_temp_dir() . '/src-list-probe';
@mkdir($dir, 0777, true);
foreach (glob($dir . '/*') as $f) {
    @unlink($f);
}

// ---------------------------------------------------------------------------
// B. Directory mtime semantics
// ---------------------------------------------------------------------------

echo "What bumps a DIRECTORY's mtime?\n";
echo str_repeat('=', 62), "\n";

file_put_contents("{$dir}/a.php", "<?php\n");
$before = statOf($dir)[0];

// Editing an existing file must NOT bump the directory.
file_put_contents("{$dir}/a.php", "<?php\n// edited\n");
$afterEdit = statOf($dir)[0];
printf("  edit a file's contents      dir mtime %s\n", $afterEdit === $before ? 'unchanged' : 'CHANGED');

// Adding a file must bump it.
file_put_contents("{$dir}/b.php", "<?php\n");
$afterAdd = statOf($dir)[0];
printf("  add a file                  dir mtime %s\n", $afterAdd !== $afterEdit ? 'CHANGED' : 'unchanged');

// Deleting must bump it.
unlink("{$dir}/b.php");
$afterDel = statOf($dir)[0];
printf("  delete a file               dir mtime %s\n", $afterDel !== $afterAdd ? 'CHANGED' : 'unchanged');

// Renaming must bump it -- this is the one a declared FILE list cannot see, since
// the old path is gone and the new path was never listed.
file_put_contents("{$dir}/c.php", "<?php\n");
$afterC = statOf($dir)[0];
rename("{$dir}/c.php", "{$dir}/d.php");
$afterRename = statOf($dir)[0];
printf("  rename a file               dir mtime %s\n", $afterRename !== $afterC ? 'CHANGED' : 'unchanged');

$dirChanges = ($afterEdit !== $before) || ($afterAdd !== $afterEdit)
    || ($afterDel !== $afterAdd) || ($afterRename !== $afterC);
if (!$dirChanges) {
    echo "\n  On this filesystem NOTHING bumped the directory mtime -- not even adding\n";
    echo "  or deleting a file. So a directory watch is not available as a cheap\n";
    echo "  structural check here, and the declared FILE list has to carry the whole\n";
    echo "  burden. That is worth knowing rather than assuming.\n";
} else {
    echo "\n  A directory catches structural changes, but not edits to a file already\n";
    echo "  in it -- so a declared FILE list is still required. Both together cover\n";
    echo "  every case.\n";
}

// ---------------------------------------------------------------------------
// A. Cost of the check
// ---------------------------------------------------------------------------

echo "\nCost of the freshness check (clearstatcache + filemtime, per path)\n";
echo str_repeat('=', 62), "\n";

// Build a realistic declared list: the routes dir plus a handful of files.
$files = [];
for ($i = 0; $i < 12; $i++) {
    $f = "{$dir}/r{$i}.php";
    file_put_contents($f, "<?php\n");
    $files[] = $f;
}

foreach ([1, 3, 5, 13] as $n) {
    $paths = array_slice(array_merge([$dir], $files), 0, $n);
    $s = [];
    for ($i = 0; $i < 500; $i++) {
        $t = hrtime(true);
        foreach ($paths as $p) {
            clearstatcache(true, $p);
            @filemtime($p);
        }
        $s[] = (hrtime(true) - $t) / 1000.0;
    }
    printf(
        "  %2d path(s)   %6.3f us\n",
        $n,
        med($s),
    );
}

// Cost against the request it is protecting. Warm first: a first-ever boot pays
// for autoloading the whole framework (~4 ms), which is not the number to compare
// against.
\App\Azera\Bootstrap::forget();
\App\Azera\Bootstrap::boot($root . '/data/bench.sqlite');

$boot = [];
for ($i = 0; $i < 200; $i++) {
    \App\Azera\Bootstrap::forget();
    $t = hrtime(true);
    \App\Azera\Bootstrap::boot($root . '/data/bench.sqlite');
    $boot[] = (hrtime(true) - $t) / 1000.0;
}
printf("\n  for scale, a cold boot is %.1f us (autoloader warm)\n", med($boot));

// And what the same check costs WITHOUT clearstatcache. PHP caches stat results, so
// the second call in the same process is served from memory -- which is exactly the
// bug a naive implementation ships: it passes for the first request in a process
// and then never notices another edit.
$fresh = "{$dir}/fresh.php";
file_put_contents($fresh, "<?php\n");
clearstatcache(true, $fresh);
filemtime($fresh);                       // prime the stat cache
file_put_contents($fresh, "<?php\n// modified after priming\n");
clearstatcache();                        // what a careless impl forgets
$stale = @filemtime($fresh);

$s = [];
for ($i = 0; $i < 500; $i++) {
    $t = hrtime(true);
    foreach ($paths as $p) {
        @filemtime($p);
    }
    $s[] = (hrtime(true) - $t) / 1000.0;
}
printf(
    "  %2d path(s) without clearstatcache: %6.3f us\n",
    count($paths),
    med($s),
);
echo "  ...cheaper, but only because PHP is answering from memory. Whether that is\n";
echo "  ALSO CORRECT depends on the SAPI, which is the next thing to measure.\n";

foreach (glob($dir . '/*') as $f) {
    @unlink($f);
}
@rmdir($dir);
