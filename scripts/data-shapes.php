<?php

declare(strict_types=1);

/*
 * The four data shapes the benchmark's read paths hand to the serializer/renderer,
 * and what each costs for the same 20 rows.
 *
 *   entities()   -> App\Azera\Models\Item   objects + identity map + snapshot
 *   objects()    -> stdClass                objects, no identity map
 *   toArray()    -> array<string,mixed>     assoc arrays (PDO::FETCH_ASSOC)
 *   arrays()     -> array<int,mixed>        positional arrays (PDO::FETCH_NUM)
 *
 * /api/items already uses the assoc-array shape, which is why it never paid the
 * hydration cost the HTML route did: ResultSet::toArray() is fetchAllAssoc(), i.e.
 * PDO::FETCH_ASSOC. So "should /api/items get a fast variant" has a different
 * answer from /items: the expensive thing is already absent, and the only thing
 * left to remove is model resolution.
 *
 * Usage: php scripts/data-shapes.php [iterations]
 */

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

use App\Azera\Models\Item;
use Azera\AppContext;

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
    printf("%-56s %8.2f us  %6.2f us/row\n", $label, $us, $us / 20);
    return $us;
}

echo "=== /api/items: the three shapes that produce the same JSON ===\n";
$assoc = t('toArray()  [assoc arrays, what it uses]', $n, function () {
    json_encode(Item::query()->orderBy('id', 'asc')->limit(20)->select()->toArray());
});
$obj = t('objects()  [stdClass per row]', $n, function () {
    $rows = [];
    foreach (Item::query()->orderBy('id', 'asc')->limit(20)->select()->fetchAllObject() as $o) {
        $rows[] = $o;
    }
    json_encode($rows);
});
$ent = t('entities() [model + identity map]', $n, function () {
    $rows = [];
    foreach (Item::query()->orderBy('id', 'asc')->limit(20)->entities() as $e) {
        $rows[] = ['id' => $e->id, 'title' => $e->title, 'created_at' => $e->created_at];
    }
    json_encode($rows);
});

printf("\n  assoc  %.2f us\n  object %.2f us  (%+.1f%% vs assoc)\n  entity %.2f us  (%+.1f%% vs assoc)\n",
    $assoc, $obj, ($obj - $assoc) / $assoc * 100, $ent, ($ent - $assoc) / $assoc * 100);

echo "\n=== /items: the two shapes the template can actually read ===\n";
// The template uses {{ item.id }} (property access), so positional/assoc arrays
// are not usable there at all; stdClass and Model both are.
$tEnt = t('entities() [what /items uses]', $n, function () {
    $p = Item::query()->paginate(1, 20);
    $p->entities();
});
$tObj = t('objects()  [what /items-fast uses]', $n, function () {
    $p = Item::query()->paginate(1, 20);
    $p->objects();
});
printf("\n  entity %.2f us -> object %.2f us  (%.1f%% saved by dropping the map)\n",
    $tEnt, $tObj, ($tEnt - $tObj) / $tEnt * 100);

echo "\n=== the assoc-array shape is the cheapest, so /api/items is already there ===\n";
printf("  per row: assoc %.2f us, object %.2f us, entity %.2f us\n",
    $assoc / 20, $obj / 20, $ent / 20);
