<?php

declare(strict_types=1);

/*
 * Does /items-fast (model-backed + objects()) differ from /items-qb
 * (raw table + objects())?
 *
 * Three paths read the same page:
 *
 *   /items       Item::query()->paginate()->entities()          model + hydration
 *   /items-fast  Item::query()->paginate()->objects()           model, no hydration
 *   /items-qb    Query::raw()->table()->paginate()->objects()   raw table, no hydration
 *
 * /items vs /items-qb changes TWO things at once (hydration AND model
 * resolution), so it conflates them. /items vs /items-fast changes exactly one.
 * The question this answers: how big is the model-resolution half that
 * /items-qb silently bundles in?
 *
 * Usage: php scripts/items-fast-compare.php [iterations]
 */

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

use App\Azera\Models\Item;
use Azera\AppContext;
use Azera\Db\Query;

$n = (int) ($argv[1] ?? 5000);

$app = new BenchApp(__DIR__ . '/../data/bench.sqlite');
$app->bootstrap();
$ctx  = AppContext::instance();
$view = $ctx->view();

function t(string $label, int $n, callable $fn): float
{
    for ($i = 0; $i < 200; $i++) {
        $fn();
        AppContext::instance()->clearRequestScope();
    }
    $t0 = hrtime(true);
    for ($i = 0; $i < $n; $i++) {
        $fn();
        AppContext::instance()->clearRequestScope();
    }
    $us = (hrtime(true) - $t0) / 1000 / $n;
    printf("%-52s %8.2f us\n", $label, $us);
    return $us;
}

// The page body, exactly as BenchController::listAction() builds it.
function page(object $p, array $items, $view, string $base): string
{
    return $view->render('items.list', [
        'baseUrl'    => $base,
        'items'      => $items,
        'pagination' => [
            'currentPage'  => $p->currentPage(),
            'lastPage'     => $p->lastPage(),
            'previousPage' => $p->previousPage(),
            'nextPage'     => $p->nextPage(),
            'totalItems'   => $p->totalItems(),
            'firstItem'    => $p->firstItem(),
            'lastItem'     => $p->lastItem(),
            'hasPrevious'  => $p->hasPrevious(),
            'hasNext'      => $p->hasNext(),
        ],
    ]);
}

echo "=== the query only (no render) ===\n";
$a = t('/items       model -> entities()  [hydration + map]', $n, function () {
    $p = Item::query()->paginate(1, 20);
    $p->entities();
    $p->totalItems();
});
$b = t('/items-fast  model -> objects()   [no hydration]', $n, function () {
    $p = Item::query()->paginate(1, 20);
    $p->objects();
    $p->totalItems();
});
$c = t('/items-qb    raw   -> objects()   [no model either]', $n, function () {
    $p = Query::raw()->table('items')->paginate(1, 20);
    $p->objects();
    $p->totalItems();
});

printf("\n  hydration (a - b):            %8.2f us\n", $a - $b);
printf("  model resolution (b - c):     %8.2f us\n", $b - $c);
printf("  total /items vs /items-qb:    %8.2f us\n", $a - $c);

echo "\n=== query + full render (what the route costs) ===\n";
$ra = t('/items       full response', $n, function () use ($view) {
    $p = Item::query()->paginate(1, 20);
    page($p, $p->entities(), $view, '/items');
});
$rb = t('/items-fast  full response', $n, function () use ($view) {
    $p = Item::query()->paginate(1, 20);
    page($p, $p->objects(), $view, '/items-fast');
});
$rc = t('/items-qb    full response', $n, function () use ($view) {
    $p = Query::raw()->table('items')->paginate(1, 20);
    page($p, $p->objects(), $view, '/items-qb');
});

printf("\n  /items -> /items-fast: %8.2f us  (%.1f%%)\n", $ra - $rb, ($ra - $rb) / $ra * 100);
printf("  /items-fast vs /items-qb: %8.2f us  (%.1f%%)\n", $rb - $rc, ($rb - $rc) / $rb * 100);

echo "\n=== byte-identity ===\n";
// All three are rendered with the SAME baseUrl, so any difference is the data
// shape and nothing else. (Comparing the real routes verbatim would also encode
// the baseUrl string, whose length differs by design — `/items` is 6 chars,
// `/items-fast` 11 — which produces a ~110 byte page difference that says
// nothing about hydration.)
$ctx->clearRequestScope();
$p1 = Item::query()->paginate(1, 20);
$h1 = page($p1, $p1->entities(), $view, '/items');
$ctx->clearRequestScope();
$p2 = Item::query()->paginate(1, 20);
$h2 = page($p2, $p2->objects(), $view, '/items');
$ctx->clearRequestScope();
$p3 = Query::raw()->table('items')->paginate(1, 20);
$h3 = page($p3, $p3->objects(), $view, '/items');

printf("  /items vs /items-fast (same baseUrl): %s  (%d / %d bytes)\n",
    $h1 === $h2 ? 'IDENTICAL' : 'DIFFERS', strlen($h1), strlen($h2));
printf("  /items vs /items-qb   (same baseUrl): %s  (%d / %d bytes)\n",
    $h1 === $h3 ? 'IDENTICAL' : 'DIFFERS', strlen($h1), strlen($h3));

if ($h1 !== $h2) {
    $len = min(strlen($h1), strlen($h2));
    for ($i = 0; $i < $len; $i++) {
        if ($h1[$i] !== $h2[$i]) {
            printf("\n  first difference at byte %d:\n    entities: %s\n    objects:  %s\n",
                $i, json_encode(substr($h1, max(0, $i - 40), 90)),
                json_encode(substr($h2, max(0, $i - 40), 90)));
            break;
        }
    }
}
