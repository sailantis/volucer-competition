<?php

declare(strict_types=1);

// Smoke-dispatch the routes the benchmark measures, against the *installed*
// framework, so a breaking change shows up here rather than on the VM.

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

$db = __DIR__ . '/../data/bench.sqlite';
if (!is_file($db)) {
    fwrite(STDERR, "missing {$db}\n");
    exit(1);
}

$app = new BenchApp($db);
$app->bootstrap();

$checks = [
    ['GET', '/echo', 200, 'bench'],
    ['GET', '/api/items', 200, null],
    ['GET', '/api/items/7', 200, null],
    ['GET', '/', 200, null],
    ['GET', '/items', 200, null],
    ['GET', '/no-such-route', 404, null],
];

$fail = 0;
foreach ($checks as [$method, $uri, $wantStatus, $wantBody]) {
    try {
        $r = $app->dispatch($method, $uri);
    } catch (\Throwable $e) {
        printf("FAIL %-6s %-18s threw %s: %s\n", $method, $uri, $e::class, $e->getMessage());
        $fail++;
        continue;
    }

    $okStatus = $r->status === $wantStatus;
    $okBody = $wantBody === null || $r->body === $wantBody;
    $status = $okStatus && $okBody ? 'ok  ' : 'FAIL';

    printf(
        "%s %-6s %-18s status=%d body=%d%s\n",
        $status,
        $method,
        $uri,
        $r->status,
        strlen($r->body),
        $wantBody === null ? '' : sprintf(' (want %s)', var_export($wantBody, true)),
    );

    if (!$okStatus || !$okBody) {
        $fail++;
        echo '     body: ' . substr($r->body, 0, 300) . "\n";
    }

    $app->cleanup();
}

// A second pass on the same instance: the resident worker must survive it.
$r = $app->dispatch('GET', '/api/items');
$again = $r->status === 200 && strlen($r->body) > 0;
echo $again ? "ok   repeat /api/items after cleanup\n" : "FAIL repeat /api/items after cleanup\n";
if (!$again) {
    $fail++;
}

echo $fail === 0 ? "\nSMOKE OK\n" : "\nSMOKE FAILED ({$fail})\n";
exit($fail === 0 ? 0 : 1);
