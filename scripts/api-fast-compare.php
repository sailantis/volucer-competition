<?php

declare(strict_types=1);

/*
 * Is there anything left to remove from /api/items?
 *
 * The controller already reads
 *
 *     Item::query()->orderBy('id','asc')->limit(20)->select()->toArray()
 *
 * so it never hydrates: no identity map, no snapshot, no instantiation. The only
 * thing a "/api/items-fast" could drop is model resolution — the model-backed
 * query resolves `items` through Item::source() and builds its column list from
 * metadata, where Query::raw()->table('items') names the table literally.
 *
 * This measures whether that half is worth a route. If it is not, adding one
 * would be a control that measures noise.
 *
 * Usage: php scripts/api-fast-compare.php [iterations]
 */

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

use App\Azera\Models\Item;
use Azera\AppContext;
use Azera\Db\Query;

$n = (int) ($argv[1] ?? 20000);

$app = new BenchApp(__DIR__ . '/../data/bench.sqlite');
$app->bootstrap();

function t(string $label, int $n, callable $fn): float
{
    for ($i = 0; $i < 300; $i++) {
        $fn();
        AppContext::instance()->clearRequestScope();
    }
    $t0 = hrtime(true);
    for ($i = 0; $i < $n; $i++) {
        $fn();
        AppContext::instance()->clearRequestScope();
    }
    $us = (hrtime(true) - $t0) / 1000 / $n;
    printf("%-56s %8.2f us\n", $label, $us);
    return $us;
}

echo "=== what the four shapes cost ===\n";
$a = t('/api/items as shipped: model -> select()->toArray()', $n, function () {
    Item::query()->orderBy('id', 'asc')->limit(20)->select()->toArray();
});
$b = t('model -> entities()   [what it does NOT do]', $n, function () {
    Item::query()->orderBy('id', 'asc')->limit(20)->entities();
});
$c = t('raw -> table->orderBy->limit->select()->toArray()', $n, function () {
    Query::raw()->table('items')->orderBy('id', 'asc')->limit(20)->select()->toArray();
});
$d = t('model -> select()->fetchAllAssoc()  [skip ResultSet]', $n, function () {
    Item::query()->orderBy('id', 'asc')->limit(20)->select()->fetchAllAssoc();
});

printf("\n  hydration it avoids (b - a):        %8.2f us\n", $b - $a);
printf("  model resolution left (a - c):      %8.2f us  (%.1f%%)\n", $a - $c, ($a - $c) / $a * 100);
printf("  ResultSet wrapper (a - d):          %8.2f us  (%.1f%%)\n", $a - $d, ($a - $d) / $a * 100);

echo "\n=== byte identity of every shape ===\n";
$shipped = json_encode(Item::query()->orderBy('id', 'asc')->limit(20)->select()->toArray());
AppContext::instance()->clearRequestScope();
$raw = json_encode(Query::raw()->table('items')->orderBy('id', 'asc')->limit(20)->select()->toArray());
AppContext::instance()->clearRequestScope();
$assoc = json_encode(Item::query()->orderBy('id', 'asc')->limit(20)->select()->fetchAllAssoc());
AppContext::instance()->clearRequestScope();

printf("  shipped      %5d bytes  md5 %s\n", strlen($shipped), md5($shipped));
printf("  raw          %5d bytes  md5 %s   %s\n", strlen($raw), md5($raw), $raw === $shipped ? 'IDENTICAL' : 'DIFFERS');
printf("  fetchAllAssoc %4d bytes  md5 %s   %s\n", strlen($assoc), md5($assoc), $assoc === $shipped ? 'IDENTICAL' : 'DIFFERS');
