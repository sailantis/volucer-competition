<?php

declare(strict_types=1);

/**
 * Why is a cold `/items` three times a warm one?
 *
 * Measured on the VM:
 *
 *   /items warm (reused connection, reused container)   113.4 us
 *   /items cold (fresh AppContext per request)          336.0 us
 *   boot, in isolation                                  155.2 us
 *
 * Boot alone does not account for the gap: 155 + 113 = 268, and the cold dispatch
 * is 336 with boot already paid. So 68 us of dispatch cost is *also* cold-start
 * work -- something that a warm worker builds once and a cold one builds per
 * request. This finds it.
 *
 * Usage: php scripts/probe-cold-dispatch.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';
require $root . '/BenchApp.php';

function med(array $xs): float
{
    sort($xs);
    $n = count($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[$n / 2 - 1] + $xs[$n / 2]) / 2;
}

$db = $root . '/data/bench.sqlite';

// --- warm baseline: one container, one connection, many requests ----------
$app = new BenchApp($db);
$app->bootstrap();
$warm = [];
for ($i = 0; $i < 300; $i++) {
    $t = hrtime(true);
    $app->dispatch('GET', '/items');
    $warm[] = (hrtime(true) - $t) / 1000.0;
    $app->cleanup();
}

// --- cold: rebuild the container every time, then time only the dispatch --
$boot = [];
$parts = ['connect' => [], 'paginate' => [], 'render' => []];
for ($i = 0; $i < 60; $i++) {
    \App\Azera\Bootstrap::forget();
    $t = hrtime(true);
    \App\Azera\Bootstrap::boot($db);
    $boot[] = (hrtime(true) - $t) / 1000.0;

    $ctx = \Azera\AppContext::instance();

    // The connection is a lazy factory, so this is the first statement and
    // therefore the connect + both PRAGMAs + the statement cache.
    $t = hrtime(true);
    $ctx->dbManager()->get('default')->query('SELECT 1');
    $parts['connect'][] = (hrtime(true) - $t) / 1000.0;

    $t = hrtime(true);
    \App\Azera\Models\Item::query()->paginate(1, 20);
    $parts['paginate'][] = (hrtime(true) - $t) / 1000.0;

    $t = hrtime(true);
    $ctx->view()->render('items.list', [
        'baseUrl' => '/items',
        'items' => [],
        'pagination' => [
            'currentPage' => 1, 'lastPage' => 1, 'previousPage' => null, 'nextPage' => null,
            'totalItems' => 0, 'firstItem' => 0, 'lastItem' => 0,
            'hasPrevious' => false, 'hasNext' => false,
        ],
    ]);
    $parts['render'][] = (hrtime(true) - $t) / 1000.0;
}

// The number this is trying to explain, measured the same way as the warm one.
$cold = [];
for ($i = 0; $i < 60; $i++) {
    \App\Azera\Bootstrap::forget();
    $a = new BenchApp($db);
    $a->bootstrap();
    $t = hrtime(true);
    $a->dispatch('GET', '/items');
    $cold[] = (hrtime(true) - $t) / 1000.0;
}

echo "/items\n";
echo str_repeat('-', 58), "\n";
printf("  warm dispatch (reused container)     %8.1f us\n", med($warm));
printf("  cold dispatch (fresh container)      %8.1f us\n", med($cold));
printf("  difference                           %8.1f us\n\n", med($cold) - med($warm));

printf("  boot, measured separately            %8.1f us\n", med($boot));
echo "\n  inside a cold dispatch:\n";
$sum = 0.0;
foreach ($parts as $k => $xs) {
    $sum += med($xs);
    printf("    %-10s                         %8.1f us\n", $k, med($xs));
}
printf("    %-10s                         %8.1f us\n", 'sum', $sum);
printf("    %-10s                         %8.1f us\n", 'unaccounted', med($cold) - $sum);

// What the connection actually costs, itemised: the two PRAGMAs run on every
// cold request and neither is free, and no warm arm ever pays them twice.
$dbh = new PDO('sqlite:' . $db);
$pragma = [];
foreach (['journal_mode = WAL', 'busy_timeout = 5000', 'cache_size = -2000', 'synchronous = NORMAL'] as $p) {
    $s = [];
    for ($i = 0; $i < 200; $i++) {
        $t = hrtime(true);
        $dbh->query('PRAGMA ' . $p);
        $s[] = (hrtime(true) - $t) / 1000.0;
    }
    $pragma[$p] = med($s);
}
$open = [];
for ($i = 0; $i < 200; $i++) {
    $t = hrtime(true);
    new PDO('sqlite:' . $db);
    $open[] = (hrtime(true) - $t) / 1000.0;
}

echo "\n  cost of opening a connection, itemised:\n";
printf("    %-28s %8.1f us\n", 'new PDO', med($open));
foreach ($pragma as $p => $us) {
    printf("    %-28s %8.1f us\n", 'PRAGMA ' . $p, $us);
}
