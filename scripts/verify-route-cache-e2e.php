<?php

declare(strict_types=1);

/**
 * End-to-end check of the cached() / restoreIfCached() round trip on the real app.
 *
 * The unit tests cover the pieces. This covers the thing that actually ships: build
 * the table through `cached()`, write it as `routes:cache` does, then boot a fresh
 * process that restores it and confirm every benchmark route still answers the same
 * bytes as an uncached boot.
 *
 * Bytes, not just status codes: a restore that quietly loses the handler's namespace
 * would still return 200 with a different page.
 *
 * Usage:
 *   php scripts/verify-route-cache-e2e.php --write     # build + write
 *   php scripts/verify-route-cache-e2e.php             # restore + compare
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';
require $root . '/BenchApp.php';

$db      = $root . '/data/bench.sqlite';
$cache   = sys_get_temp_dir() . '/e2e-routes.php';
$expect  = sys_get_temp_dir() . '/e2e-expect.json';
$write   = in_array('--write', $argv, true);

$paths = ['/echo', '/', '/items', '/items-fast', '/items/7', '/api/items', '/api/items/7', '/items-qb'];

/** Boot the app normally (no cache) and hash each response. */
function snapshot(string $db, array $paths): array
{
    \App\Azera\Bootstrap::forget();
    putenv('BENCH_ROUTE_CACHE');
    $app = new BenchApp($db);
    $app->bootstrap();

    $out = [];
    foreach ($paths as $p) {
        $r = $app->dispatch('GET', $p);
        $out[$p] = ['status' => $r->status, 'md5' => md5($r->body), 'len' => strlen($r->body)];
    }
    return $out;
}

if ($write) {
    // The recording path. `recordSources(true)` has to be on before boot, because
    // boot is what registers the routes -- which is exactly why the app reads it from
    // the environment rather than a query parameter.
    \App\Azera\Bootstrap::forget();
    putenv('BENCH_ROUTE_RECORD=1');
    putenv('BENCH_ROUTE_CACHE');

    $ctx    = \App\Azera\Bootstrap::boot($db);
    $router = $ctx->router();
    $src    = $router->recordedSources();

    if ($src === null) {
        fwrite(STDERR, "FAIL: no sources recorded -- is Bootstrap wrapping routes in cached()?\n");
        exit(1);
    }

    $state               = $router->exportState();
    $state['__sources']  = $src['files'];
    $state['__compiled'] = time();
    file_put_contents($cache, '<?php return ' . var_export($state, true) . ";\n");

    file_put_contents($expect, json_encode(snapshot($db, $paths), JSON_PRETTY_PRINT));
    printf("wrote %s (%.1f KB) and %s\n", $cache, filesize($cache) / 1024, basename($expect));
    printf("recorded sources: %s\n", implode(', ', array_map('basename', $src['files'])));
    exit(0);
}

// --- restore path ---------------------------------------------------------
if (!is_file($cache) || !is_file($expect)) {
    fwrite(STDERR, "run with --write first\n");
    exit(1);
}

require $cache;
if (function_exists('opcache_is_script_cached') && !opcache_is_script_cached($cache)) {
    fwrite(STDERR, "FAIL: cache file is not in opcache; the restore timing would be a compile\n");
    exit(1);
}

\App\Azera\Bootstrap::forget();
putenv("BENCH_ROUTE_CACHE={$cache}");
$app = new BenchApp($db);
$app->bootstrap();

$want = json_decode((string) file_get_contents($expect), true);
$bad  = 0;
foreach ($paths as $p) {
    $r    = $app->dispatch('GET', $p);
    $got  = ['status' => $r->status, 'md5' => md5($r->body), 'len' => strlen($r->body)];
    $ok   = $got == $want[$p];
    if (!$ok) {
        $bad++;
    }
    printf(
        "  %-16s %s  status %d  %d bytes%s\n",
        $p,
        $ok ? 'ok  ' : 'FAIL',
        $got['status'],
        $got['len'],
        $ok ? '' : '  expected md5 ' . $want[$p]['md5'] . ', got ' . $got['md5'],
    );
}

echo $bad === 0
    ? "\nE2E OK: restored table answers identically on all " . count($paths) . " routes\n"
    : "\nE2E FAILED ({$bad})\n";
exit($bad === 0 ? 0 : 1);
